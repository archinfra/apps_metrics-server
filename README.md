# app_metrics-server

面向 Kubernetes 的 `metrics-server` 离线安装仓库，产出单文件 `.run` 包。

当前实现目标很明确：
- 支持 `amd64` / `arm64` 离线构建
- 支持 `install` / `uninstall` / `status`
- 支持把官方镜像离线导入并推送到本地仓库
- 支持常见集群兼容参数
  - `--kubelet-insecure-tls`
  - `--host-network`
  - `--replicas 2`

当前版本基于官方最新 release：
- metrics-server `v0.8.1`
- 官方安装清单来源：[`components.yaml`](https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.8.1/components.yaml)

## metrics-server 是做什么的

`metrics-server` 是 Kubernetes 的资源指标聚合组件。

它的作用主要有 3 个：
- 给 `kubectl top nodes` / `kubectl top pods` 提供 CPU、内存实时数据
- 给 `HPA` 提供基于 CPU / 内存的伸缩指标
- 给 `VPA` 等自动调优链路提供基础资源指标

它不是 Prometheus 的替代品，也不适合做长期监控、告警、历史分析。  
如果你需要完整监控体系，还是应该用 Prometheus / VictoriaMetrics 这类方案。

官方说明：
- [Metrics Server 官方主页](https://kubernetes-sigs.github.io/metrics-server/)
- [Metrics Server Releases](https://github.com/kubernetes-sigs/metrics-server/releases)

## 仓库结构

```text
.
|-- .github/workflows/build-offline-installer.yml
|-- build.sh
|-- install.sh
|-- images/
|   `-- image.json
`-- manifests/
    `-- metrics-server.yaml.tmpl
```

说明：
- `build.sh`
  拉取官方镜像，打成 payload，并生成最终 `.run`
- `install.sh`
  最终 installer 入口脚本
- `images/image.json`
  离线镜像定义
- `manifests/metrics-server.yaml.tmpl`
  基于官方 `components.yaml` 改造的参数化模板

## 构建

先确保本地有：
- `bash`
- `docker`
- `python` or `python3`

构建命令：

```bash
chmod +x build.sh install.sh
./build.sh --arch amd64
./build.sh --arch arm64
./build.sh --arch all
```

产物：

```text
dist/metrics-server-installer-amd64.run
dist/metrics-server-installer-amd64.run.sha256
dist/metrics-server-installer-arm64.run
dist/metrics-server-installer-arm64.run.sha256
```

## 安装器动作

### install

安装或对齐当前 `metrics-server` 资源。

```bash
./dist/metrics-server-installer-amd64.run install -y
```

### uninstall

卸载 `metrics-server` 资源。

```bash
./dist/metrics-server-installer-amd64.run uninstall -y
```

### status

查看当前状态。

```bash
./dist/metrics-server-installer-amd64.run status
```

## 常用参数

- `-n, --namespace`
  默认 `kube-system`
- `--replicas`
  默认 `1`，设置为 `2` 时会自动开启简单 HA 形态
- `--registry`
  默认 `sealos.hub:5000/kube4`
- `--registry-user`
  默认 `admin`
- `--registry-pass`
  默认 `passw0rd`
- `--skip-image-prepare`
  跳过镜像导入和推送，适合镜像已提前准备好的环境
- `--image-pull-policy`
  默认 `IfNotPresent`
- `--metric-resolution`
  默认 `15s`
- `--kubelet-preferred-address-types`
  默认 `InternalIP,ExternalIP,Hostname`
- `--kubelet-insecure-tls`
  忽略 kubelet 证书校验，适合测试集群或自签 kubelet 证书环境
- `--host-network`
  metrics-server Pod 使用 `hostNetwork`
- `--wait-timeout`
  默认 `5m`
- `-y, --yes`
  跳过确认

## 常见安装示例

### 1. 默认安装

```bash
./dist/metrics-server-installer-amd64.run install -y
```

### 2. 测试集群开启 kubelet 证书跳过校验

```bash
./dist/metrics-server-installer-amd64.run install \
  --kubelet-insecure-tls \
  -y
```

### 3. 双副本高可用

```bash
./dist/metrics-server-installer-amd64.run install \
  --replicas 2 \
  -y
```

### 4. 使用 hostNetwork

```bash
./dist/metrics-server-installer-amd64.run install \
  --host-network \
  -y
```

### 5. 镜像已经提前同步，跳过镜像导入

```bash
./dist/metrics-server-installer-amd64.run install \
  --skip-image-prepare \
  -y
```

### 6. 自定义本地仓库前缀

```bash
./dist/metrics-server-installer-amd64.run install \
  --registry harbor.example.com/kube4 \
  -y
```

## 安装后验证

先看基础资源：

```bash
kubectl get deployment -n kube-system metrics-server
kubectl get pods -n kube-system -l k8s-app=metrics-server
kubectl get svc -n kube-system metrics-server
kubectl get apiservice v1beta1.metrics.k8s.io
```

再看指标接口是否可用：

```bash
kubectl top nodes
kubectl top pods -A
```

如果 `kubectl top` 暂时还没有数据，先看日志：

```bash
kubectl logs -n kube-system deploy/metrics-server
```

## 常见问题

### 1. `kubectl top` 没数据

通常看这几类原因：
- kube-apiserver aggregation layer 没开
- apiserver 到 metrics-server Pod 网络不通
- metrics-server 到 kubelet 网络不通
- kubelet 证书不是集群 CA 签发

这类测试环境最常见的处理方式是：

```bash
./dist/metrics-server-installer-amd64.run install \
  --kubelet-insecure-tls \
  -y
```

### 2. 需要不需要 Prometheus

需要。  
`metrics-server` 负责资源指标聚合和 autoscaling 基础能力，不负责长期监控。

### 3. 双副本是不是完整高可用

不是完整平台级 HA，只是官方推荐的基础高可用形态：
- `replicas=2`
- `PodDisruptionBudget`
- `podAntiAffinity`

如果你的 apiserver 侧也要更稳，建议额外开启：
- `--enable-aggregator-routing=true`

这是 kube-apiserver 的参数，不在当前 installer 内处理。

## GitHub Actions

触发规则：
- push 到 `main/master`
- push `v*` tag
- 手工 `workflow_dispatch`

产物：
- `metrics-server-installer-amd64.run`
- `metrics-server-installer-arm64.run`

如果是 `v*` tag，还会自动创建 GitHub Release。
