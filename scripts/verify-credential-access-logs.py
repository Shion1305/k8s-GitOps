#!/usr/bin/env python3
"""Translate the real proxy manifests, then exercise their loggers in Envoy.

Requires egctl 1.9.0, kustomize, yq, openssl and Docker. --translate-only runs
the offline translation checks without claiming that runtime checks passed.
Only freshly generated certificates and synthetic request markers are used.
"""

import argparse
import base64
import copy
import json
from pathlib import Path
import socket
import ssl
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
HOST = "credentials.research.shion.dev"
ENVOY = ("envoyproxy/envoy:distroless-v1.39.0@sha256:"
         "7877ad87afd7459e1bd2a077ff601fec7c93aeecd62e71664560d96328c62cf4")
CEL_TYPE = "type.googleapis.com/envoy.extensions.access_loggers.filters.cel.v3.ExpressionFilter"


def run(*args, input=None):
    return subprocess.check_output(args, input=input, text=True, cwd=ROOT)


def yaml_documents(path):
    return json.loads(run("yq", "eval-all", "-o=json", "[.]", str(path)))


def access_logs(value, path=""):
    if isinstance(value, dict):
        for key, child in value.items():
            if key == "accessLog":
                stdout = [log for log in child
                          if log.get("typedConfig", {}).get("path") == "/dev/stdout"]
                if stdout:
                    yield path, stdout
            else:
                yield from access_logs(child, f"{path}.{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            yield from access_logs(child, f"{path}[{index}]")


def remove_cel(log_filter, expression):
    extension = log_filter.get("extensionFilter", {}).get("typedConfig", {})
    if extension.get("@type") == CEL_TYPE:
        assert extension["expression"] == expression, "Unexpected CEL expression"
        return None
    if "andFilter" in log_filter:
        remaining = [remove_cel(child, expression)
                     for child in log_filter["andFilter"]["filters"]]
        remaining = [child for child in remaining if child is not None]
        return ({"andFilter": {"filters": remaining}} if len(remaining) > 1
                else remaining[0] if remaining else None)
    return log_filter


def translate(egctl, resources, directory, name):
    source = directory / f"{name}.yaml"
    source.write_text("\n---\n".join(json.dumps(resource) for resource in resources))
    return json.loads(run(egctl, "x", "translate", "--from", "gateway-api",
                          "--to", "xds", "--type", "all", "--output", "json",
                          "--add-missing-resources", "--file", str(source)))


def translated_loggers(egctl, directory):
    rendered = directory / "gateway.yaml"
    rendered.write_text(run("kustomize", "build", "envoy-gateway"))
    manifests = yaml_documents(rendered)
    routes = []
    for filename in ["gh-leaked-tokens/credential-exposure-study/httproute.yaml",
                     "harbor/httproute-external.yaml", "harbor/httproute-internal.yaml"]:
        routes.extend(yaml_documents(ROOT / filename))
    representatives = None
    expressions = []
    for proxy_name, class_name in [("instance-k8s-proxy", "envoy-default"),
                                   ("home", "envoy-home")]:
        # egctl translates one GatewayClass at a time. Real listener, route and
        # proxy manifests are retained; only referenced TLS/backend data is fake.
        resources = [copy.deepcopy(resource) for resource in manifests if resource and (
            resource["kind"] == "EnvoyProxy" and resource["metadata"]["name"] == proxy_name
            or resource["kind"] == "GatewayClass" and resource["metadata"]["name"] == class_name
            or resource["kind"] == "Gateway" and resource["spec"]["gatewayClassName"] == class_name)]
        resources.extend(copy.deepcopy(routes))
        for namespace in ["envoy-gateway-system", "gh-leaked-tokens", "harbor"]:
            resources.append({"apiVersion": "v1", "kind": "Namespace", "metadata": {
                "name": namespace, "labels": {"kubernetes.io/metadata.name": namespace}}})
        names = {ref["name"] for resource in resources if resource["kind"] == "Gateway"
                 for listener in resource["spec"]["listeners"]
                 for ref in listener.get("tls", {}).get("certificateRefs", [])}
        for name in sorted(names):
            resources.append({"apiVersion": "v1", "kind": "Secret", "metadata": {
                "name": name, "namespace": "envoy-gateway-system"}, "type": "kubernetes.io/tls",
                "data": {key: base64.b64encode((directory / filename).read_bytes()).decode()
                         for key, filename in [("tls.crt", "cert.pem"), ("tls.key", "key.pem")]}})
        proxy = next(resource for resource in resources if resource["kind"] == "EnvoyProxy")
        settings = proxy["spec"]["telemetry"]["accessLog"]["settings"]
        assert len(settings) == 1 and "type" not in settings[0]
        assert "format" not in settings[0], "Keep the version's default JSON format"
        assert len(settings[0]["matches"]) == 1
        expression = settings[0]["matches"][0]
        expressions.append(expression)
        desired = dict(access_logs(translate(egctl, resources, directory, class_name)))
        baseline_resources = copy.deepcopy(resources)
        baseline_proxy = next(r for r in baseline_resources if r["kind"] == "EnvoyProxy")
        del baseline_proxy["spec"]["telemetry"]["accessLog"]
        baseline = dict(access_logs(translate(egctl, baseline_resources, directory, f"{class_name}-baseline")))
        assert desired and desired.keys() == baseline.keys(), "Logger locations changed"
        for path, loggers in desired.items():
            assert len(loggers) == len(baseline[path]) == 1, "Duplicate/default logger remains"
            actual, previous = loggers[0], baseline[path][0]
            assert actual["typedConfig"] == previous["typedConfig"], "Format/destination changed"
            assert remove_cel(actual["filter"], expression) == previous.get("filter"), path
            assert CEL_TYPE in json.dumps(actual["filter"]), "Filter was ignored by translator"
        http = next(loggers[0] for path, loggers in desired.items() if path.endswith(".typedConfig"))
        listener = next(loggers[0] for path, loggers in desired.items() if path.endswith(".listener"))
        if representatives:
            assert representatives == (http, listener), "Proxy loggers differ"
        representatives = (http, listener)
        print(f"{class_name}: {len(desired)} generated logger locations checked; no duplicates or format changes")
    assert expressions[0] == expressions[1]
    return representatives


def runtime_config(http_log, listener_log):
    routes = [
        {"match": {"prefix": "/r/rejected"}, "directResponse": {"status": 403}},
        {"match": {"prefix": "/s/error"}, "directResponse": {"status": 503}},
        {"match": {"prefix": "/r/redirect"}, "redirect": {"pathRedirect": "/", "responseCode": "FOUND"}},
        *[{"match": {"prefix": prefix}, "directResponse": {"status": 200}}
          for prefix in ["/r/", "/s/"]],
    ]
    hcm = {"name": "envoy.filters.network.http_connection_manager", "typedConfig": {
        "@type": "type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager",
        "statPrefix": "synthetic_privacy_check", "normalizePath": True,
        "pathWithEscapedSlashesAction": "UNESCAPE_AND_REDIRECT",
        "routeConfig": {"name": "synthetic", "virtualHosts": [{"name": "synthetic", "domains": ["*"], "routes": routes}]},
        "httpFilters": [{"name": "envoy.filters.http.router", "typedConfig": {
            "@type": "type.googleapis.com/envoy.extensions.filters.http.router.v3.Router"}}],
        "accessLog": [http_log]}}
    tls = {"name": "envoy.transport_sockets.tls", "typedConfig": {
        "@type": "type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.DownstreamTlsContext",
        "commonTlsContext": {"tlsCertificates": [{"certificateChain": {"filename": "/fixture/cert.pem"},
                                                    "privateKey": {"filename": "/fixture/key.pem"}}]}}}
    listeners = []
    for port, use_tls in [(10080, False), (10443, True), (10444, True)]:
        chain = {"filters": [copy.deepcopy(hcm)]}
        listener = {"name": f"synthetic-{port}", "address": {"socketAddress": {
            "address": "0.0.0.0", "portValue": port}}, "accessLog": [listener_log], "filterChains": [chain]}
        if use_tls:
            chain["transportSocket"] = tls
            listener["listenerFilters"] = [{"name": "envoy.filters.listener.tls_inspector", "typedConfig": {
                "@type": "type.googleapis.com/envoy.extensions.filters.listener.tls_inspector.v3.TlsInspector"}}]
        if port == 10444:
            chain["filterChainMatch"] = {"serverNames": ["accepted.example.test"]}
        listeners.append(listener)
    return {"staticResources": {"listeners": listeners}}


def request(port, host, path, sni=None, extra_headers=""):
    connection = socket.create_connection(("127.0.0.1", port), timeout=5)
    if sni is not None:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE  # Fresh synthetic certificate, localhost only.
        connection = context.wrap_socket(connection, server_hostname=sni)
    with connection:
        connection.sendall((f"GET {path} HTTP/1.1\r\nHost: {host}\r\n"
                            f"{extra_headers}Connection: close\r\n\r\n").encode())
        response = b""
        while chunk := connection.recv(65536):
            response += chunk
    return int(response.split(b" ", 2)[1])


def runtime_check(directory, loggers):
    (directory / "envoy.json").write_text(json.dumps(runtime_config(*loggers)))
    container = run("docker", "run", "--detach", "--rm", "--read-only", "--user", "0",
                    "--cap-drop", "ALL", "--security-opt", "no-new-privileges", "--tmpfs", "/tmp",
                    "-v", f"{directory}:/fixture:ro", "-p", "127.0.0.1::10080",
                    "-p", "127.0.0.1::10443", "-p", "127.0.0.1::10444", ENVOY,
                    "-c", "/fixture/envoy.json", "--disable-hot-restart", "--log-level", "warning").strip()
    private_markers, control_markers = [], []
    try:
        ports = {port: int(run("docker", "port", container, str(port)).strip().rsplit(":", 1)[1])
                 for port in [10080, 10443, 10444]}
        deadline = time.monotonic() + 10
        while True:
            try:
                request(ports[10080], HOST, "/r/readiness")
                break
            except OSError:
                if time.monotonic() > deadline:
                    raise AssertionError("Envoy did not accept the translated CEL configuration")
                time.sleep(0.1)
        paths = [("/r/{marker}", 200), ("/s/{marker}", 200), ("/r/rejected-{marker}", 403),
                 ("/s/error-{marker}", 503), ("/r/redirect-{marker}", 302),
                 ("/missing/{marker}", 404), ("/r/example?cap={marker}", 200),
                 ("/r/%61-{marker}", 200), ("/r%2F{marker}", 307),
                 ("/r/../s/{marker}", 200), ("/r/%00{marker}", 400)]
        for transport in [10080, 10443]:
            for template, status in paths:
                marker = f"synthetic-private-{len(private_markers)}"
                private_markers.append(marker)
                assert request(ports[transport], HOST, template.format(marker=marker),
                               HOST if transport == 10443 else None) == status
        for authority, sni in [(HOST.upper() + ":443", "control.example.test"),
                               (HOST + ".:443", "control.example.test"),
                               ("control.example.test", HOST),
                               ("control.example.test", HOST.upper())]:
            marker = f"synthetic-private-{len(private_markers)}"
            private_markers.append(marker)
            assert request(ports[10443], authority, f"/r/{marker}", sni) == 200
        for authority, path, status in [("control.example.test", "/r/{}", 200),
                                        ("control.example.test", "/missing/{}", 404),
                                        ("control.example.test", "/s/error-{}", 503),
                                        ("prefix-" + HOST, "/r/{}", 200),
                                        (HOST + ".example.test", "/r/{}", 200)]:
            marker = f"synthetic-control-{len(control_markers)}"
            control_markers.append(marker)
            assert request(ports[10443], authority, path.format(marker), "control.example.test",
                           f"X-Forwarded-Host: {HOST}\r\nForwarded: host={HOST}\r\n") == status
        # Listener-only failures have no HTTP request attributes. Preserve
        # unrelated diagnostics, suppress this site's SNI without evaluation errors.
        for sni in [HOST, "synthetic-control-handshake.example.test"]:
            try:
                request(ports[10444], sni, "/r/unused", sni)
                raise AssertionError("Expected unmatched TLS filter chain")
            except (ssl.SSLError, ConnectionError):
                pass
        control_markers.append("synthetic-control-handshake.example.test")
        deadline = time.monotonic() + 5
        while True:
            logs = subprocess.run(["docker", "logs", container], text=True, capture_output=True, check=True)
            combined = logs.stdout + logs.stderr
            assert not any(marker in combined for marker in private_markers), "Private marker reached logs"
            for line in logs.stdout.splitlines():
                if line.startswith("{"):
                    record = json.loads(line)
                    for field in [":authority", "requested_server_name"]:
                        identity = str(record.get(field, "")).split(":", 1)[0].lower().rstrip(".")
                        assert identity != HOST, "Credential authority/SNI reached logs"
            if all(marker in combined for marker in control_markers):
                break
            assert time.monotonic() < deadline, "Unrelated-host logging or listener diagnostics disappeared"
            time.sleep(0.1)
        for marker in control_markers:
            assert logs.stdout.count(marker) == 1, "Unexpected duplicate logger"
        print(f"Envoy 1.39: {len(private_markers)} private HTTP cases + private TLS failure suppressed; "
              f"{len(control_markers)} unrelated HTTP/TLS controls logged exactly once")
    finally:
        subprocess.run(["docker", "rm", "--force", container], capture_output=True, check=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--egctl", default="egctl")
    parser.add_argument("--translate-only", action="store_true")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="credential-log-check-") as temp:
        directory = Path(temp)
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                        "-keyout", str(directory / "key.pem"), "-out", str(directory / "cert.pem"),
                        "-subj", "/CN=synthetic.example.test"], check=True, capture_output=True)
        loggers = translated_loggers(args.egctl, directory)
        if args.translate_only:
            print("Translation only: real Envoy runtime checks were not run")
        else:
            runtime_check(directory, loggers)


if __name__ == "__main__":
    main()
