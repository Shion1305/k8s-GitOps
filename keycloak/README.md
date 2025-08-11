# Keycloak Configuration for Docker Registry Authentication

## Overview
This Keycloak setup provides Docker Registry v2 authentication with GitHub Actions OIDC integration for the zot registry.

## Current Working Configuration

### Authentication Details
- **Admin User**: `admin`
- **Admin Password**: `admin123` (configured in values.yaml)
- **Database**: External PostgreSQL via Zalando operator

### Realms and Clients

#### Master Realm
- Used for Keycloak administration
- Admin access via `admin`/`admin123`

#### Registry Realm
- **Name**: `registry`
- **Display Name**: Docker Registry
- **Access Token Lifespan**: 900 seconds (15 minutes)
- **External URL**: https://keycloak.k.shion1305.com/realms/registry

#### Clients

1. **docker-registry**
   - **Protocol**: docker-v2
   - **Type**: Public client
   - **Purpose**: Docker registry authentication endpoint

2. **gha-exchanger**
   - **Protocol**: openid-connect
   - **Type**: Confidential client
   - **Service Accounts**: Enabled (required for client_credentials flow)
   - **Direct Access**: Enabled
   - **Purpose**: GitHub Actions OIDC token exchange
   - **Client Secret**: `dJV7CaroUsFWCeAl2ZBSc5E44odX60uH`

#### Identity Provider
- **Name**: github-actions
- **Type**: OIDC
- **Issuer**: https://token.actions.githubusercontent.com
- **Client ID**: zot-actions
- **JWKS URL**: https://token.actions.githubusercontent.com/.well-known/jwks
- **Sync Mode**: IMPORT

#### Claim Mappers
The following GitHub Actions claims are mapped to user attributes:
- `repository` → repository
- `ref` → ref  
- `actor` → actor
- `sha` → sha

### Kubernetes Resources

#### Secrets
- `keycloak`: Contains admin-password
- `keycloak-postgres-credentials`: PostgreSQL credentials (synced from Zalando operator)
- `gha-exchanger-credentials`: GitHub Actions client credentials
  - `client-id`: gha-exchanger
  - `client-secret`: dJV7CaroUsFWCeAl2ZBSc5E44odX60uH

#### Services
- `keycloak`: Main Keycloak service (ClusterIP, port 8080)
- `keycloak-headless`: Headless service for StatefulSet

#### Ingress
- **Hostname**: keycloak.k.shion1305.com
- **Class**: nginx-ssl
- **TLS**: Enabled
- **Annotations**:
  - `nginx.ingress.kubernetes.io/proxy-buffer-size: "16k"`
  - `nginx.ingress.kubernetes.io/proxy-buffers-number: "8"`
  - `nginx.ingress.kubernetes.io/proxy-busy-buffers-size: "32k"`

## Token Exchange Flow

### GitHub Actions → Keycloak
1. GitHub Actions provides OIDC token
2. gha-exchanger client exchanges GitHub token for Keycloak access token
3. Access token used for Docker registry authentication

### Docker Registry Integration
- **Auth URL**: https://keycloak.k.shion1305.com/realms/registry/protocol/docker-v2/auth
- **Service**: registry.k.shion1305.com
- **Scope**: Repository-based access control

## Validation Commands

### Admin Token Test
```bash
curl -s -X POST "http://keycloak.keycloak.svc.cluster.local:8080/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=admin&password=admin123&grant_type=password&client_id=admin-cli"
```

### Client Credentials Test
```bash
curl -s -X POST "http://keycloak.keycloak.svc.cluster.local:8080/realms/registry/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials&client_id=gha-exchanger&client_secret=dJV7CaroUsFWCeAl2ZBSc5E44odX60uH"
```

### Registry Realm Test
```bash
curl -s https://keycloak.k.shion1305.com/realms/registry
```

## Bootstrap Job
The `keycloak-realm-bootstrap` job automatically configures:
- Registry realm creation
- Docker registry client setup
- GitHub Actions identity provider
- Claim mappers configuration  
- GHA exchanger client with service accounts enabled
- Client secret generation and logging

## Files Structure
```
keycloak/
├── values.yaml              # Helm chart values
├── realm-bootstrap.yaml     # Bootstrap job configuration
├── secrets.yaml            # Secret templates
├── secret-sync.yaml        # PostgreSQL credential sync job
└── README.md               # This documentation
```

## Status: ✅ HEALTHY
- Keycloak ingress accessible at keycloak.k.shion1305.com
- Admin authentication working
- Registry realm configured and accessible
- All clients and IdP properly configured
- Token exchange flows validated
- Ready for zot registry integration
