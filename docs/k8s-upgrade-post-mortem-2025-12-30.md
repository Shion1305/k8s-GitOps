# ポストモーテム: Kubernetes 1.34 へのアップグレード不全とスケジューラ障害

## 概要
- 発生日時: 2025-12-30 10:45–12:45 UTC
- 影響範囲:
  - API Server が v1.33.1 のまま停止せず、クラスター全体がバージョン不整合（kubelet/kubectl は v1.34.3）に
  - kube-scheduler のRBAC不足により CronJob を含む新規Podが Pending 停滞
- 影響度: 高（新規スケジューリング不可、アップグレード停滞）
- 最終状態: 2025-12-30 12:44 UTC 時点で Control Plane/ノードとも v1.34.3 へ収束、CoreDNS v1.12.1（1.34系の推奨タグ）に整合

## 事象の詳細（タイムライン）
- 10:52 UTC kubeadm upgrade apply v1.34.3 実施。etcd は更新成功、kube-apiserver フェーズで 5分タイムアウト（ロールバック発生）。
- 11:10–11:30 UTC クラスターは Server v1.33.1 のまま、ノードは v1.34.3。CronJob が Pending 停滞。scheduler ログに「forbidden」多数。
- 11:35–12:20 UTC API Server マニフェストは v1.34.3 だが Pod は v1.33.1 で起動する事象を確認。
- 12:40 UTC /etc/kubernetes/manifests 直下に kube-apiserver.yaml.bak（v1.33.1）が残置されていることを特定。
- 12:42–12:44 UTC .bak をディレクトリ外へ退避、kubelet 再起動。API Server が v1.34.3 で再生成・安定化。
- 12:45 UTC kubeadm-config の kubernetesVersion=v1.34.3 を確認。スケジューラRBACを補正後、スケジューリング正常化。

## 技術的な根本原因（RCA）
1. 重複したスタティックPodマニフェスト
   - /etc/kubernetes/manifests/kube-apiserver.yaml（v1.34.3）と、同ディレクトリ内の kube-apiserver.yaml.bak（v1.33.1）が併存。
   - kubelet はディレクトリ内の「有効なYAMLすべて」を監視し、同一名のPod定義の競合を招いた結果、古いイメージ（v1.33.1）でミラーポッドを継続生成。

2. kubeadm の静的Pod更新タイムアウト
   - kubeadm の control-plane 更新は各コンポーネント 5分タイムアウトに固定。ARM/リソース制約環境で再起動・準備に時間を要し、apiserver フェーズが繰り返しタイムアウト→ロールバック。

3. kube-scheduler のRBAC欠落
   - 以前のRBAC削除影響で、schedulerに必要な権限（Pods/Nodes/PVs/ConfigMaps/Storage/Resource APIs等）が欠落し、スケジューリングイベント発火不可。

## 影響
- 新規Pod（CronJob含む）がPendingで停滞。
- コンポーネントのバージョン不整合（デバッグ困難化、将来のローリング/証明書更新リスク）。
- アップグレードの再試行が毎回タイムアウト→ロールバックする非生産的ループ。

## 検知・診断
- kubectl version で Client/Server のバージョン乖離を検知。
- kube-system の apiserver Pod イメージ（v1.33.1）とマニフェスト（v1.34.3）の不一致を確認。
- manifests ディレクトリ内の *.bak 残置を確認。
- scheduler ログの forbidden を手掛かりに ClusterRole 権限不足を特定。

## 復旧手順（実施内容）
- /etc/kubernetes/manifests/kube-apiserver.yaml.bak をディレクトリ外へ移動（manifests.backups/）。
- kubelet を再起動して static Pod を再生成、kube-apiserver v1.34.3 稼働を確認。
- kubeadm-config（kubeadm の ClusterConfiguration）の kubernetesVersion を v1.34.3 に整合。
- scheduler の ClusterRole を包括的に再定義・適用（必要なリソース群へ get/list/watch/update/patch 等を付与）。
- CoreDNS イメージが v1.12.1（1.34 の推奨）であることを確認、kube-proxy v1.34.3 を確認。

## 再発防止策（アクションアイテム）
- スタティックPod運用
  - バックアップファイル（*.bak など）を /etc/kubernetes/manifests 直下に置かない。専用バックアップディレクトリを使用。
  - CI/ヘルスチェックで「manifests に同一Pod名の複数定義や *.bak の存在」を検知・アラート。
- アップグレード運用
  - 事前に kubeadm config images pull を実行（イメージプル遅延によるタイムアウト回避）。
  - コントロールプレーンノードの一時的なリソース確保（CPU/メモリ/IOヘッドルーム確保）。
  - kubeadm upgrade のヘルスチェックJob失敗時は意味づけの上で --ignore-preflight-errors=CreateJob などで段階実行（フェーズ分割）を検討。
- RBAC管理
  - 重要RBAC（cluster-admin、scheduler、controller-manager など）をGitOps管理（本件では argocd-rbac アプリを導入済）。
  - 重要なClusterRole/Bindingの削除・変更をアラート（Audit/OPA/Gatekeeper/ValidatingWebhook 等の導入も検討）。
- 可観測性
  - バージョン乖離（Server/Node/kubectl）をダッシュボード可視化・アラート。
  - scheduler の forbidden/error レート監視（ログベース/メトリクス）。

## 参考コマンド（抜粋）
```bash
# バージョンとイメージ整合確認
kubectl version -o json | jq -r '.serverVersion.gitVersion'
kubectl -n kube-system get pod kube-apiserver-... -o jsonpath='{.spec.containers[0].image}'

# manifests 内の競合確認
ls -l /etc/kubernetes/manifests
grep -n "image:" /etc/kubernetes/manifests/*.yaml*

# kubeadm-config の確認
kubectl -n kube-system get cm kubeadm-config -o jsonpath='{.data.ClusterConfiguration}'
```

## 教訓
- スタティックPod運用では「ディレクトリ内の全ての有効YAMLが対象」になる。バックアップは同ディレクトリに置かない。
- kubeadm の 5分タイムアウトは環境次第で不足しうる。事前プル・リソース確保・フェーズ分割が有効。
- RBAC は「失ってからでは遅い」。GitOpsでの管理と保護が不可欠。
