# 从零到一:基于 GitLab 搭一套自己的 CI/CD 环境

> 这是仓库内快照,文中提到的脚本、compose 与三份语言样例都在仓库根目录,操作手册见 [`README.md`](../README.md)。

> 不看公司现成环境,自己把 GitLab、Runner、流水线、部署门禁、Release 一整条链路搭一遍,才算真正理解 CI/CD。本文记录我在一台 16 GB 内存 Apple Silicon 的 Mac 上,用 Docker 从零搭起本地 GitLab CI/CD 的全过程:起 GitLab CE、注册 Runner、跑绿第一条流水线,最后落成 Rust / Java / C++ 三条真实语言的 CI/CD 流水线——staging 自动部署、production 人工门禁、发布成功自动打 Release。文中所有时间数字都是实测。

## 先看成品

最终架构长这样:

```text
          浏览器 / git push
                │
                ▼  http://gitlab.127.0.0.1.nip.io:8929
┌────────────────────────── Docker ──────────────────────────┐
│                                                            │
│   ┌──────────────┐    push 触发流水线                       │
│   │  GitLab CE   │◀───────────────────────────────  开发者 │
│   │ Web/API/仓库 │                                         │
│   └──────┬───────┘                                         │
│          │ Runner 长轮询领任务                               │
│   ┌──────▼──────────┐  每个任务拉起一个独立容器  ┌───────────┐ │
│   │  GitLab Runner  │─────────────────────────▶│ job 容器   │ │
│   │ docker executor │                          │ alpine /  │ │
│   └─────────────────┘                          │ rust/maven│ │
│         gitlab-net 自定义网络(GitLab 服务别名保证容器内可解析)│
└────────────────────────────────────────────────────────────┘
     数据(配置/仓库/日志)全部落在宿主机 ~/gitlab-docker,容器随时可删
```

几个实测数字,给要不要往下读一个参照:

- GitLab 全新数据目录冷启动到 API 可用约 90 秒到 2 分钟;已有数据重启约 75 秒;日常重复执行幂等脚本约 20 秒;
- 三种语言热缓存下单任务 2~5 秒,一条 build → test → verify → deploy:staging 流水线约 10 秒跑完,停在 production 人工门禁;
- 镜像与依赖全部本地化之后,断网也能跑 CI。

## 第 0 步:选型与预算

- **GitLab CE(omnibus 镜像)**:代码托管、CI 配置、环境/部署/发布管理一体,一个容器全带走;
- **GitLab Runner + Docker executor**:每个任务在独立容器里执行,环境干净、可复现,不污染宿主机;
- **硬件**:GitLab 本体占 4~6 GB 内存,加上 Runner 和任务容器,物理内存建议 ≥ 16 GB;gitlab-ce 镜像约 6 GB,首次拉取建议先配好 registry 镜像加速;
- **版本**:我装的是 GitLab 18.8。18 有个对搭建流程影响很大的变化——**runner 的 registration token 被移除了**,注册改成"先通过 API 创建 runner 记录、再拿 `glrt-` 认证 token 注册"。网上大量教程还停留在旧方式,照抄会直接失败,第 3 步按新方式来。

前置依赖只有:`docker`(带 compose 插件)、`git`、`curl`、`python3`、`openssl`,以及配好 git 提交身份(脚本要替 demo 项目建提交)。

## 第 1 步:先解决域名——最大的坑其实在 DNS

这是整件事里最值得先讲的一步。`external_url` 不只是个 Web 地址:GitLab 用它推导仓库 clone URL,CI 任务克隆代码用的 `CI_REPOSITORY_URL` 又由 clone URL 推导。所以这个域名必须**同时在三个地方可用**:

1. 你的浏览器(Mac 宿主机);
2. Runner 容器(领任务、回报状态);
3. CI 任务容器(克隆代码)。

候选方案逐个排除:

- `localhost`:浏览器里可用;但 Runner 和任务容器里的 `localhost` 是容器自己,GitLab 不可达;
- `host.docker.internal`:容器里可用,宿主机不解析,浏览器打不开;
- 写 `/etc/hosts`:能解决,但要 sudo,而且每个任务容器都得想办法注入。

最终用的是 **nip.io**:公共通配 DNS,`<任意前缀>.127.0.0.1.nip.io` 一律解析到 `127.0.0.1`。宿主机和容器都能解析,免 sudo。还剩一个隐患——容器内解析依赖外网 DNS,断网就挂。所以 compose 里再给 GitLab 服务加一个同名网络别名:

```yaml
services:
  gitlab:
    networks:
      gitlab-net:
        aliases:
          - gitlab.127.0.0.1.nip.io
```

这样容器之间走 Docker 内置 DNS 就能解析,只有浏览器那一次查询真正需要外网 DNS。

两个实测备注:个别 IDE 的内置浏览器会把"公网域名解析到回环地址"当作本地网络访问拦掉,一个请求都不发,用 Safari/Chrome 确认即可;如果你的环境连外网 DNS 都没有,退回 `/etc/hosts` 方案——`echo '127.0.0.1 gitlab.local' | sudo tee -a /etc/hosts`,启动时把 host 换成 `gitlab.local`,效果等价。

## 第 2 步:docker-compose 起 GitLab CE

compose 文件不长,关键就三处(完整版见仓库根目录 `docker-compose.yml`)。

**一、资源裁剪。** omnibus 镜像默认按大机器配置,个人机必须调小,否则内存直接吃满:

```yaml
environment:
  GITLAB_OMNIBUS_CONFIG: |
    external_url 'http://gitlab.127.0.0.1.nip.io:8929'
    gitlab_rails['gitlab_shell_ssh_port'] = 2224
    puma['worker_processes'] = 2
    sidekiq['max_concurrency'] = 10
    prometheus['enable'] = false
    prometheus_monitoring['enable'] = false
    alertmanager['enable'] = false
    postgres_exporter['enable'] = false
    redis_exporter['enable'] = false
    gitlab_exporter['enable'] = false
```

Prometheus 监控全家桶全关——这台机器上整个 GitLab 稳定运行在 4~6 GB 内存,就是靠这份裁剪。HTTP 用 8929、git over SSH 用 2224,避开本机已占用的端口;`shm_size: 256m` 兜底。

**二、数据全部落盘宿主机**,容器随时可删可重建:

```yaml
volumes:
  - ~/gitlab-docker/config:/etc/gitlab
  - ~/gitlab-docker/logs:/var/log/gitlab
  - ~/gitlab-docker/data:/var/opt/gitlab
```

**三、healthcheck 用官方的 `gitlab-healthcheck`**,首次启动 `start_period` 放到 300 秒——首次启动要跑完整的数据库迁移和 reconfigure,实测全新数据目录 90 秒到 2 分钟 API 才可用,期间 `docker logs -f gitlab` 能看到进度。

## 第 3 步:注册 Runner(GitLab 18 的新姿势)

Runner 容器本身很简单,真正要紧的是两处挂载/组网:挂 `docker.sock`(Docker executor 靠它起任务容器)、接入和 GitLab 相同的自定义网络(任务容器要在网络里按名字找到 GitLab):

```yaml
gitlab-runner:
  image: gitlab/gitlab-runner:latest
  volumes:
    - ~/gitlab-docker/runner-config:/etc/gitlab-runner
    - /var/run/docker.sock:/var/run/docker.sock
  networks:
    - gitlab-net
```

然后是注册。**GitLab 18 移除了 registration token**,新流程两段式:

```bash
# ① 通过 API 创建 runner 记录,拿到 glrt- 开头的认证 token
curl -s -X POST -H "PRIVATE-TOKEN: $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{
    "description": "dev-env-runner",
    "runner_type": "instance_type",
    "tag_list": ["mac"],
    "run_untagged": true,
    "maximum_timeout": 3600
  }' http://gitlab.127.0.0.1.nip.io:8929/api/v4/user/runners

# ② 用 glrt- token 非交互注册
docker exec -i gitlab-runner gitlab-runner register --non-interactive \
  --url http://gitlab.127.0.0.1.nip.io:8929/ \
  --token glrt-xxxx \
  --executor docker \
  --docker-image alpine:latest \
  --docker-volumes /cache \
  --docker-network-mode gitlab-net \
  --docker-pull-policy if-not-present
```

两个细节:用 `glrt-` token 注册时,`tags`、`run_untagged` 由服务端(第 ① 步的 API 参数)管理,`register` 拒绝在本地重复设置,别按旧教程加 `--run-untagged` 之类的参数;`--docker-pull-policy if-not-present` 现在记不住没关系,第 7 步踩坑时回来讲——它是"本机自建镜像能不能用进 CI"的开关。

## 第 4 步:第一条绿色流水线

还差三样东西:API token、一个项目、一份 `.gitlab-ci.yml`。

**拿 API token。** 本地环境不想每次手输 root 密码,直接从 Rails 控制台铸一个 30 天 token。先随机生成秘密值存到 `~/gitlab-docker/dev-env-token`(600 权限),再让容器执行一小段 Ruby:

```ruby
user = User.find_by_username('root')
token = PersonalAccessToken.new(
  user: user, name: 'dev-env-local',
  scopes: %i[api read_repository write_repository],
  expires_at: Time.current + 30.days)
token.set_token(ENV.fetch('DEV_ENV_TOKEN'))
token.save
```

这个 token 同时充当 git push 的密码(用户名 `oauth2`)。push 时不想把 token 写进 `.git/config`,用一次性认证头:

```bash
git -c http.extraHeader="Authorization: Basic $(printf 'oauth2:%s' "$TOKEN" | openssl base64 -A)" push gitlab main
```

**建项目、推流水线。** API 建一个 `ci-demo` 私有项目,本地 init 仓库,推一份最小配置:

```yaml
stages:
  - verify

untagged-job:
  stage: verify
  image: alpine:latest
  script:
    - echo "hello from GitLab CI"
    - echo "project ${CI_PROJECT_PATH} pipeline ${CI_PIPELINE_ID}"

tagged-job:
  stage: verify
  tags: [mac]
  image: alpine:latest
  script:
    - echo "this job only runs on a runner tagged mac"
```

一个不带 `tags`(验证 `run_untagged` 生效)、一个带 `tags`(验证标签路由生效),一条流水线把 Runner 接活的两条路径都测到。

**轮询到绿。** 每 10 秒查一次 `GET /projects/:id/pipelines/:id`,`success` 收工;`failed` 就把失败任务 trace 的最后 30 行打出来。第一次看到这行输出,链路就通了:

```text
pipeline 1: http://gitlab.127.0.0.1.nip.io:8929/root/ci-demo/pipelines/1
pipeline 1 succeeded
```

至此,GitLab 托管代码、Runner 领任务、任务在 Docker 容器里执行、结果回写,整个闭环全部验证过。

## 第 5 步:把这一切脚本化,并且幂等

手工搭完一遍后,我把所有步骤收进一个脚本(仓库根目录的 `gitlab-ci.sh`):`up` 一条命令从零跑到"一条流水线成功",`status` 看状态,`down` 停容器。真正费心思的是幂等设计,保证反复执行不产生垃圾:

- token 已存在且有效 → 复用,不重铸;
- demo 项目已存在 → 跳过创建;
- 已有在线可用的 runner → 直接复用;只有状态为 `never_contacted`(从未连上、无法自愈)的同名僵尸记录才删掉重建;
- demo 提交无变化 → 不重复 push;
- 上次留下的流水线是 failed → 对同一 commit 新起一条,而不是复述旧失败。

所以重复执行 `up` 的成本只有约 20 秒,大部分时间在等容器健康检查。

## 第 6 步:从 CI 到 CD:真实项目的完整流水线

smoke 流水线只能证明"通",还不够"用"。真实项目需要完整的 CD:`build → test → verify → deploy:staging → deploy:production → release` 六个阶段,staging 在 main 上自动部署,production 人工门禁,发布成功自动打 Release。Rust / Java / C++ 三份模板共用这套骨架,以 Rust 为例:

```yaml
stages:
  - build
  - test
  - verify
  - deploy
  - release

variables:
  # 与 Cargo.toml 的 [package] version 一起改,build 任务负责校验一致
  APP_VERSION: "0.2.0"

workflow:
  rules:
    # release 关键字会创建 tag,不挡住的话 tag 又会触发第二条流水线
    - if: $CI_COMMIT_TAG
      when: never
    - if: $CI_COMMIT_BRANCH == "main"

default:
  image: rust:1.92-slim
  tags: [mac]
  cache:
    key: rust-1.92-slim
    paths:
      - .cargo/registry/
      - target/

build:
  stage: build
  script:
    - grep -q "^version = \"${APP_VERSION}\"" Cargo.toml
    - cargo build --release --offline --locked
  artifacts:
    paths:
      - target/release/rust-hello
    # 回滚靠重跑旧部署任务,它需要这条流水线的产物,不能过期太快
    expire_in: 1 week

test:
  stage: test
  script:
    - cargo test --release --offline --locked

verify:
  stage: verify
  needs:
    - job: build
      artifacts: true
  script:
    - ./target/release/rust-hello verify

deploy:staging:
  stage: deploy
  needs:
    - job: build
      artifacts: true
  environment:
    name: staging
  script:
    - ./target/release/rust-hello staging

deploy:production:
  stage: deploy
  when: manual                # 人工门禁:流水线停在这里等人点
  allow_failure: false        # 没有它,manual 被跳过不影响流水线状态
  resource_group: production  # 同一环境的部署跨流水线串行,防并发写
  needs:
    - job: build
      artifacts: true
    - job: deploy:staging
  environment:
    name: production
  script:
    - ./target/release/rust-hello production

# release-cli 必须在任务镜像里,业务镜像里没有,所以拆成独立任务
release:
  stage: release
  image: registry.gitlab.com/gitlab-org/release-cli:latest
  needs:
    - job: deploy:production
  script:
    - echo "released rust-hello v${APP_VERSION}"
  release:
    tag_name: v${APP_VERSION}
    name: rust-hello v${APP_VERSION}
    description: "Deployed from pipeline ${CI_PIPELINE_ID} of ${CI_COMMIT_SHORT_SHA}."
```

几个设计点:

- **`when: manual` 必须配 `allow_failure: false`**,否则流水线带着一个被跳过的 manual 任务照样显示成功,门禁形同虚设;配上之后流水线停在 `blocked`,UI 上点一下才继续往下走;
- **`resource_group: production`** 是部署锁:两个 commit 前后脚推上来,也不会并发写同一个环境;
- **`needs` + artifacts**:部署任务不重新构建,直接取 build 产物,保证"测过的就是部署的";
- **版本号单一来源**:真实版本只写在 `Cargo.toml` / `pom.xml` / `CMakeLists.txt`,`APP_VERSION` 只是 CI 侧引用,build 任务里一行 `grep` 强制两者对齐,漂移直接 fail。

三种语言的差异集中在镜像选择和缓存策略:

| | Rust | Java | C++ |
| --- | --- | --- | --- |
| 镜像 | `rust:1.92-slim`(1.13 GB) | `maven:3.9-eclipse-temurin-17`(809 MB) | 本机自建 `linux-dev:ubuntu20`(770 MB) |
| 缓存 | `.cargo/registry/` + `target/` | `.m2/repository/` | 不缓存 |
| build 实测(热缓存) | 2.6s | 4.9s(冷 15.1s) | 2.8s |

Java 版特意把 Maven 配置放进仓库(`ci/settings.xml`,只有一条 aliyun mirror),而不是拷贝本机 `~/.m2/settings.xml`——后者带着 `<server>` 凭据和代理配置,进 CI 既不可复现也不该提交;本地仓库用 `-Dmaven.repo.local=$CI_PROJECT_DIR/.m2/repository` 指进项目目录,才能被 `cache.paths` 收进缓存包。冷缓存 build 15.1 秒,暖缓存 4.9 秒,差别全在这里。

C++ 版用的是本机自建的编译镜像(g++ 9.4 + cmake 3.16 + ninja,registry 上没有对应仓库),它的前提正是第 7 步要讲的 pull policy 改造。

跑起来的效果:推送后约 5 秒流水线停在 production 门禁(前四段全绿),点批准,15 秒后 production 与 release 相继 success。Environments 页多出两条部署记录,Releases 页出现 `v0.1.0`。这条链路三种语言各完整跑绿了一遍。

## 第 7 步:踩坑实录

下面都是这一路真实撞上的坑,按"疼的程度"排序。

**① Runner 的镜像拉取策略,挡住了所有本地镜像。** 想让 CI 用本机构建好的 `linux-dev:ubuntu20`(registry 上不存在),任务在准备阶段就挂:

```text
ERROR: Job failed: failed to pull image "linux-dev:ubuntu20" with specified
policies [always]: ... 403 Forbidden
```

GitLab Runner 18 的 `allowed_pull_policies` 默认只有 `always`,每个任务都先问一遍 registry;在 `.gitlab-ci.yml` 里写 `image.pull_policy: never` 也救不了——任务级覆盖归 `allowed_pull_policies` 管,只能在 runner 配置里改:

```toml
# ~/gitlab-docker/runner-config/config.toml 的 [runners.docker] 段
pull_policy = "if-not-present"
```

改完 `docker restart gitlab-runner` 生效。之后本地有镜像就直接用,trace 变成 `Using locally found image version due to "if-not-present" pull policy`——顺带省掉了每次任务连 registry 问一圈的 1~2 秒,断网也能跑 CI。新注册 runner 直接带 `--docker-pull-policy if-not-present` 即可,不用事后补。

**② `release:` 关键字对任务镜像有隐藏要求。** 最初把 release 挂在构建任务上,部署脚本明明打印了 `hello, production!`,任务却判失败:

```text
/usr/bin/bash: line 193: release-cli: command not found
```

`release:` 的执行体(release-cli 或 glab)必须存在于任务自己的镜像里,而 Rust / Maven / 编译镜像里都没有。解法:release 拆成独立任务,镜像用官方的 `registry.gitlab.com/gitlab-org/release-cli:latest`(90 MB,拉取不到 10 秒)。

**③ Release 打的 tag 会触发第二条流水线。** `release` 创建 `v0.1.0` 这样的 tag,而 tag 默认也起流水线,每次发布后面会跟一条空转的 tag 流水线。解法是模板顶部的 `workflow: rules`:`$CI_COMMIT_TAG → when: never`,只放行 main。

**④ 缓存目录必须在 `$CI_PROJECT_DIR` 下。** Maven 默认往 `~/.m2` 写,但 runner 的 cache 只打包 `cache.paths` 声明的、项目目录内的路径。不把 `maven.repo.local` 指进 `$CI_PROJECT_DIR`,缓存就是空转。另外首跑必见 `WARNING: cache file does not exist`,那是冷缓存的正常现象,不是故障。

**⑤ Rust slim 镜像没有 rustfmt 和 clippy。** `/usr/local/cargo/bin` 里软链接在、组件没装,补装要联网。轻量镜像和离线构建是硬币两面:要么换 full 镜像,要么接受 lint 不在这一层做。另一个小坑:别用 `bash -lc` 跑 cargo——登录 shell 会重读 `/etc/profile`,把 `/usr/local/cargo/bin` 从 PATH 里丢掉。

**⑥ 每个任务都是全新容器,`build/` 不会跨任务留存。** 所以 C++ 模板的 test 任务要自己重新 `cmake` 一遍(也就 2 秒)。为什么不干脆缓存 `build/`?一它会和 artifacts 里的产物抢路径;二 CMake 缓存里写的是 `/builds/...` 绝对路径,换了容器照样要重新 configure,收益抵不上坑。大项目要提速,正路是装 ccache 并缓存 `~/.ccache`。

**⑦ GitLab 18.8 没有回滚 REST 端点。** Environments 页上那颗 Rollback 按钮,本质就是重跑那次部署的任务。API 等价操作:

```bash
curl -X POST -H "PRIVATE-TOKEN: $TOKEN" \
  http://gitlab.127.0.0.1.nip.io:8929/api/v4/projects/3/jobs/96/retry
```

这要求那次流水线的 artifacts 还在——所以 `expire_in: 1 week` 不是随手写的,产物一过期,回滚就是无米之炊。实测重试后新部署记录的 commit 正确回到旧版本。

## 日常运维速查

- `gitlab-ci.sh status`:容器健康、runner 在线状态、最近三条流水线一眼看完;
- `gitlab-ci.sh down`:停容器、数据全保留;彻底重置 = down 之后删掉 `~/gitlab-docker/{config,data}`(不可逆,会丢项目历史);
- 忘记 root 密码,Rails 控制台直接重设(密码放单引号里,`!` 出现在双引号里会被 bash 历史展开咬一口):

```bash
docker exec -i -e PW='YourNewPass1!' gitlab /opt/gitlab/bin/gitlab-rails runner \
  'user = User.where(username: "root").first; puts user.update(password: ENV["PW"], password_confirmation: ENV["PW"])'
```

- **长时间关机后 job 全部 HTTP 500**:日志里是 `PG::CheckViolation: no partition of relation "project_daily_statistics" found for row`——动态分区表没建出当月分区,补一刀再重跑:

```bash
docker exec gitlab gitlab-rails runner 'Database::PartitionManagementWorker.perform_async'
```

- **UI 登录报 `422: The change you requested was rejected`**:不是密码错,是标签页的 CSRF token 过期(改密码会撤销全部会话)。关掉旧标签页重开登录页即可;另外 `127.0.0.1` 和 nip.io 是两个 cookie 域,别来回切;
- **job 长期 pending**:多半是 runner 掉线或 tags 对不上,`gitlab-ci.sh status` 确认,必要时 `docker exec gitlab-runner gitlab-runner verify`。

## 写在最后

回头看,这套环境真正花时间的不是"把 GitLab 跑起来"——compose 一把梭的事——而是三件别的:

1. **让浏览器、Runner、任务容器在同一个域名上会师**(nip.io + 网络别名的组合拳);
2. **让 CI 不依赖外网也能拿到镜像和依赖**(pull policy、仓库内配置、项目内缓存目录);
3. **把流水线配置打磨成工程纪律**:版本号单一来源、部署有门禁、发布可回滚。

这三件事都有一锤定音的解,踩过一遍之后就变成自己的 checklist。完整可复现的材料都在仓库根目录:一键脚本 `gitlab-ci.sh`、compose 文件、Rust / Java / C++ 三份跑绿过的 CI/CD 模板,以及一份更细的 README —— https://github.com/xinchentechnote/gitlab-ci-from-zero-to-one

如果这篇文章对你有用,搭的时候撞了别的坑,欢迎交流。
