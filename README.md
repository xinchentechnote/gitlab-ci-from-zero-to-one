# 本地 GitLab + Runner 一键跑通 CI

[`gitlab-ci.sh`](gitlab-ci.sh) 用 Docker 启动 GitLab CE 和一个以 Docker executor 执行任务的 GitLab Runner，并把整条链路跑到「一条流水线成功」为止：起容器 → 等 GitLab 就绪 → 生成 API token → 建 demo 项目 → 确保 runner 在线 → 推送 `.gitlab-ci.yml` → 轮询流水线结果。

配置和数据放在仓库外的 `~/gitlab-docker`（可用 `--dir` 改），仓库里只有 compose 和脚本。

除了 `ci-demo`，[`examples/`](examples) 下还有 Rust / Java / C++ 三份能直接跑的 CI/CD 模板，见「跑 Rust / Java / C++ 项目」。

这套环境的搭建过程和踩坑记录见 [`docs/gitlab-ci-from-zero-to-one.md`](docs/gitlab-ci-from-zero-to-one.md)，本文是操作与运维手册。

## 前置条件

- Docker 守护进程已启动，并带 `docker compose` 插件；GitLab 全家桶大约占用 4–6 GB 内存，建议物理内存 ≥ 16 GB。
- `git`、`curl`、`python3`、`openssl`。
- 已拉取 `gitlab/gitlab-ce:latest` 与 `gitlab/gitlab-runner:latest`。Apple Silicon 上这两个镜像有 arm64 版本（本机 GitLab 镜像为 18.8.4），首次拉取 GitLab 镜像约 6 GB，建议先配好 registry 镜像加速。
- 已设置 git 提交身份（脚本要为 demo 项目建提交）：

```bash
git config --global user.name "xinchen"
git config --global user.email "you@example.com"
```

## 最简用法

```bash
./gitlab-ci.sh          # 等价于 ./gitlab-ci.sh up
```

实测：已有数据时从冷容器到 API 可用约 75 秒，全新数据目录（含建库迁移）约 90 秒到 2 分钟；Docker 虚机冷缓存、磁盘慢时会明显久一些，默认预算 900 秒，可用 `--ready-timeout` 放宽。重复执行是安全的：token、项目、runner、demo 提交都已存在时只做检查并复用，最后一次 `up` 约 20 秒。

实际输出（数据目录已存在、runner 已在线的情况）：

```text
==> GitLab http://gitlab.127.0.0.1.nip.io:8929 with data in ~/gitlab-docker
 Container gitlab Running
 Container gitlab-runner Running
GitLab API already answering at http://gitlab.127.0.0.1.nip.io:8929
reusing the API token at ~/gitlab-docker/dev-env-token
project root/ci-demo already exists (id 2)
runner already online and usable: 3 docker-runner
reusing the local demo checkout at ~/gitlab-docker/projects/ci-demo
demo project already committed and pushed
pipeline 3: http://gitlab.127.0.0.1.nip.io:8929/root/ci-demo/pipelines/3
pipeline 3 succeeded

==> ready
GitLab UI     http://gitlab.127.0.0.1.nip.io:8929   (username root)
...
```

## 访问方式

| 用途 | 地址 |
| --- | --- |
| Web UI | `http://gitlab.127.0.0.1.nip.io:8929`，用户名 `root` |
| HTTP clone | `http://gitlab.127.0.0.1.nip.io:8929/<namespace>/<repo>.git`，密码用 token：用户名 `oauth2`，口令为 `~/gitlab-docker/dev-env-token` 里的值 |
| SSH clone | `ssh://git@gitlab.127.0.0.1.nip.io:2224/<namespace>/<repo>.git`（需在 UI 里添加你的公钥） |

脚本不会修改 root 密码，它通过 Rails 控制台签发一个名为 `dev-env-local`、有效期 30 天的 API token。忘记 root 密码时可以直接重设（会让其他已登录会话失效）：

```bash
docker exec -i -e PW='YourNewPass1!' gitlab /opt/gitlab/bin/gitlab-rails runner \
  'user = User.where(username: "root").first; puts user.update(password: ENV["PW"], password_confirmation: ENV["PW"])'
```

打印 `true` 即生效。密码请写进单引号里：`!` 出现在双引号中会被 shell 当成历史展开而报 `event not found`；密码里也不要带单引号。

### 为什么域名是 `gitlab.127.0.0.1.nip.io`

`external_url` 必须同时在三处可用：浏览器、Runner 容器、以及 CI 任务容器（job 克隆代码用的 `CI_REPOSITORY_URL` 由 `external_url` 推导）。

- `localhost` 只在浏览器和 Mac 上好用，容器里的 `localhost` 是容器自己；
- `host.docker.internal` 只在容器里好用，本机不解析；
- 写 `/etc/hosts` 需要 sudo。

nip.io 是公共通配 DNS，`<任意前缀>.127.0.0.1.nip.io` 一律返回 `127.0.0.1`，本机与容器都能解析且免 sudo。compose 还给 GitLab 服务加了同名网络别名，因此容器内的解析不依赖外网 DNS，只有浏览器那一次查询需要。

浏览器实测备注：`dscacheutil`/`dns-sd`（也就是 Safari、Chrome 走的系统解析路径）能解析该域名，但 Qoder 内置浏览器打不开它——内置浏览器一个请求都没发出，像是把「公网域名解析到回环地址」当作本地网络访问拦掉了。请在自己的 Safari/Chrome 里打开一次确认；打不开就换成本地域名：

```bash
# 一次性操作，需要你输入 sudo 密码
echo '127.0.0.1  gitlab.local' | sudo tee -a /etc/hosts
./gitlab-ci.sh --host gitlab.local
```

`--host` 改动会重新触发 reconfigure，之后浏览器、runner、CI 克隆都会跟着换。

## 参数

命令行参数与同名环境变量等价：

```text
--dir PATH                 配置/日志/数据/runner 注册的根目录，默认 $HOME/gitlab-docker
--host NAME                访问域名，默认 gitlab.127.0.0.1.nip.io
--port PORT                HTTP 端口，默认 8929
--ssh-port PORT            git over SSH 端口，默认 2224
--network NAME             Runner 与任务容器共用的 Docker 网络，默认 gitlab-net
--tag LIST                 注册 runner 时的标签，默认 mac
--project NAME             demo 项目名，默认 ci-demo
--namespace NAME           demo 项目命名空间，默认 root
--ready-timeout SECONDS    等待 GitLab 启动的预算，默认 900
--pipeline-timeout SECONDS 等待流水线结束的预算，默认 600
```

只跑容器、不做后续自动化的话，直接用 compose：

```bash
cd gitlab && docker compose up -d
```

## 状态与停止

```bash
./gitlab-ci.sh status   # 容器健康、runner 状态、demo 项目最近三条流水线
./gitlab-ci.sh down     # 停止容器，保留 config/logs/data/runner-config
```

## 接到自己的仓库

```bash
cd ~/workspace/my-project
git remote add gitlab http://gitlab.127.0.0.1.nip.io:8929/root/my-project.git
```

在 GitLab UI 建好项目后推送即可。需要指定用这台 runner 时给任务加标签：

```yaml
build:
  stage: build
  tags:
    - mac
  script:
    - make build
```

不带 `tags` 的任务也能跑：脚本注册的 runner 打开了 `run_untagged`。推送时避免把 token 写进 `.git/config`，可以临时带头：

```bash
git -c http.extraHeader="Authorization: Basic $(printf 'oauth2:%s' "$(cat ~/gitlab-docker/dev-env-token)" | openssl base64 -A)" push gitlab main
```

## 跑 Rust / Java / C++ 项目

`examples/` 下三份可直接复制的 CI/CD 模板，都已推到 GitLab 并跑绿（CI 侧 build → test → verify → deploy:staging 自动，production 人工门禁，成功后建 Release，骨架三语言共用，见「CD」一节）：

| 样例 | 项目 | 镜像（本机已有） | build | test | verify | deploy:staging |
| --- | --- | --- | --- | --- | --- | --- |
| `examples/rust-hello` | `root/rust-hello`（id 3） | `rust:1.92-slim`（1.13 GB） | 2.6s | 2.5s | 2.2s | 2.2s |
| `examples/java-hello` | `root/java-hello`（id 4） | `maven:3.9-eclipse-temurin-17`（809 MB） | 4.9s | 4.0s | 2.4s | 2.5s |
| `examples/cpp-hello` | `root/cpp-hello`（id 5） | `linux-dev:ubuntu20`（770 MB） | 2.8s | 2.3s | 2.0s | 2.0s |

表里是 pipeline 48 / 47 / 46（同一 commit 重新起的流水线，缓存已热）的单个任务墙钟时间。runner 配置 `concurrent = 1`，任务实际是排队串行跑的，所以四条任务加起来约 10 秒，推送结束到停在人工门禁就按这个量级看。首次冷缓存更慢：Java 的 build 是 15.1s（要下全插件和 junit），Rust 冷跑约 20 秒。

### Rust

镜像选 `rust:1.92-slim`：本机已有该镜像（1.13 GB，arm64），版本和宿主 `cargo 1.92.0` 一致，任务不用下载。几条实测结论：

- **零依赖 + `--offline --locked`**：`Cargo.lock` 已在样例里提交，`cargo build/test` 加 `--offline` 后不碰 crates.io，`--locked` 保证锁文件不漂移。样例只有一个 `greet()` 和一条单测，不引任何 crate，就是为了在这台网络受限的机器上稳定复现。要真依赖 crates.io 时把 `--offline` 去掉，并确认 `CARGO_HOME` 指向缓存目录（见下面「缓存」一条）。
- **slim 镜像没有 rustfmt 和 clippy 组件**：`/usr/local/cargo/bin` 里有 `cargo-fmt`、`clippy-driver` 的软链接，但执行是 `error: 'rustfmt' is not installed for the toolchain '1.92.0-aarch64-unknown-linux-gnu'`，补装要联网拉 static.rust-lang.org。所以模板里不放 fmt/lint 任务。
- 另外别用 `bash -lc` 跑 cargo：登录 shell 会重读 `/etc/profile`，把 `/usr/local/cargo/bin` 从 PATH 里丢掉（runner 默认用非登录 shell，不受影响；手工 `docker run ... bash -lc 'cargo --version'` 会 command not found）。
- **runner 的镜像策略已改成 `if-not-present`，任务不再访问 registry**。GitLab Runner 18 的 `allowed_pull_policies` 默认只有 `always`，在 `.gitlab-ci.yml` 里写 `image.pull_policy: never` 会被直接拒绝：`ERROR: Job failed: invalid pull policy for image "rust:1.92-slim": pull_policy ([never]) defined in GitLab pipeline config is not one of the allowed_pull_policies ([always])`——任务级覆盖归 `allowed_pull_policies` 管，只能改 runner 配置。2026-02 手工注册那份 `config.toml` 里原本没有 `pull_policy`，走默认 `always`：每次任务都问一次 registry（trace 里的 `Pulling docker image rust:1.92-slim ...`），实测 1.5～2 秒命中镜像加速源后仍用本地镜像，但代价是**本地自建镜像（registry 上没有对应仓库）根本用不了**，C++ 样例第一次就是这么挂的：`ERROR: Job failed: failed to pull image "linux-dev:ubuntu20" with specified policies [always]: ... failed to resolve reference "docker.io/library/linux-dev:ubuntu20": unexpected status from HEAD request to https://docker.m.daocloud.io/v2/library/linux-dev/manifests/ubuntu20?ns=docker.io: 403 Forbidden`。2026-10-27 给 `~/gitlab-docker/runner-config/config.toml` 的 `[runners.docker]` 补了一行 `pull_policy = "if-not-present"` 并 `docker restart gitlab-runner`，之后三种语言的 trace 都变成：
  ```text
  Using effective pull policy of [if-not-present] for container rust:1.92-slim
  Using locally found image version due to "if-not-present" pull policy
  ```
  断网也能跑 CI。要回滚就删掉那一行再 `docker restart gitlab-runner`（runner 重启不会自己重写这份文件，实测改动只多了那一行）；`/tmp/config.toml.before-pull-policy` 是改动前的原文备份，`/tmp` 会被系统清，想长期留着就 `cp` 一份走。注意 `gitlab-ci.sh` 新注册的 runner 本来就带 `--docker-pull-policy if-not-present`，这次只是把 2026-02 那份对齐。
- **缓存**：`CARGO_HOME=$CI_PROJECT_DIR/.cargo`、`CARGO_TARGET_DIR=$CI_PROJECT_DIR/target`，配 `cache.paths: [.cargo/registry/, target/]`。首跑必打印 `WARNING: Cache file does not exist` / `Failed to extract cache`，冷缓存的正常现象；零依赖项目还会提示 `.cargo/registry/: no matching files`，因为 registry 目录压根没被创建。缓存走 runner 本地（`No URL provided` → 不上传共享缓存服务），只在同一台 runner 上复用。

### Java

`maven:3.9-eclipse-temurin-17`（809 MB）首次 `docker pull` 实测 2m27s，走的是宿主 Docker 的镜像加速源；下过一次之后本地就有，JDK 17 和宿主一致。要点：

- **Maven 的配置要进仓库，不从 `~/.m2` 借**。样例用 `ci/settings.xml`，里面只有一条 aliyun mirror，任务里 `mvn -B -s ci/settings.xml -Dmaven.repo.local=$CI_PROJECT_DIR/.m2/repository`。没有拷你本机那份 `~/.m2/settings.xml`：它带 `<server>` 凭据位和 proxy 段，是给别的项目用的，进 CI 既不可复现也不该提交。
- **这台机器上 `repo1.maven.org` 从容器里是通的**（实测建连 0.19s），宿主机上那个 DNS 超时不代表容器也不行；但阿里云镜像在容器里跑到 6.2～18 MB/s，pom/jar 都明显更快，所以默认 `mirrorOf: *` 指过去。真要连中心库，把 `ci/settings.xml` 里那条 mirror 删掉即可。
- **本地仓库目录必须指到 `$CI_PROJECT_DIR` 下才能被 `cache.paths` 收到**：`.m2/repository/`、`cache.key: maven-3.9-temurin17`。冷缓存 build 15.1s，暖缓存 4.9s，test 6.7s → 4.0s。
- **产物版本号只有一个来源**：`pom.xml` 的 `<version>`。`maven-jar-plugin` 配 `addDefaultImplementationEntries=true`，MANIFEST 里就有 `Implementation-Version`，代码用 `getPackage().getImplementationVersion()` 读，所以 CI 只需 `grep -q "<version>${APP_VERSION}</version>" pom.xml` 把 `APP_VERSION` 和 pom 对齐，升级改两处。
- 任务里跑的是 `java -jar target/java-hello-${APP_VERSION}.jar`，和部署后真正的启动方式一致；`verify`/`deploy:*` 都直接跑同一个 jar 产物（`needs: build` 取 artifacts）。

### C++

镜像直接用你本机自建的 `linux-dev:ubuntu20`：Ubuntu 20.04.6，`g++ 9.4.0`、`cmake 3.16.3`、GNU Make 4.2.1、ninja 1.10.0，770 MB，不用再去拉 1.5 GB 的 `gcc:` 官方镜像。**前提是 runner 的 pull policy 已经是 `if-not-present`**（上面 Rust 一节最后一条），否则这种 registry 上不存在的镜像在准备阶段就失败。要点：

- **CMake 3.16 没有 `ctest --test-dir`**（那是 3.20+ 才有的），所以 test 任务写成 `sh -c 'cd build && ctest --output-on-failure'`。
- **每个任务都是全新容器，`build/` 不跨任务复用**，因此 test 任务自己重新 `cmake -S . -B build && cmake --build build`（2.3s）。这个模板故意不给 C++ 配 `cache`：缓存整个 `build/` 会和 `artifacts` 里的 `build/cpp-hello` 抢路径，而 CMake 生成的缓存里带绝对路径（`/builds/...`），换容器照样要重新 configure，缓存收益抵不上坑。真要大项目提速就挂 ccache（`linux-dev:ubuntu20` 里没装，得自己 `apt install ccache` 或换镜像），然后缓存 `~/.ccache` 并配 `CMAKE_CXX_COMPILER_LAUNCHER=ccache`。
- 版本号在 `CMakeLists.txt` 的 `project(cpp-hello VERSION 0.1.0)`，通过 `target_compile_definitions(cpp-hello PRIVATE HELLO_VERSION="${PROJECT_VERSION}")` 编进二进制；build 任务用 `grep -q "project(cpp-hello VERSION ${APP_VERSION}"` 对齐 CI 变量。
- 库写成 `add_library(greeter INTERFACE)` + `target_include_directories(... INTERFACE)`，可执行和测试都 link 它，样例小但也走正常的 target 结构。

### CD：staging 自动、production 手动门禁、成功打 Release

三份模板共用同一套骨架，只有镜像、构建命令和产物路径不同。完整阶段是 `build → test → verify → deploy:staging → deploy:production → release`。staging 在 `main` 上自动跑；production 是 `when: manual` + `allow_failure: false`，所以流水线会停在 `manual` 等人工点，点完才继续建 Release tag。实测（pipeline 43）：推送后约 5 秒停在人工门禁，此时前四条任务已全绿；点批准之后 15 秒 production 与 release 都是 `success`。Java（pipeline 44）和 C++（pipeline 45）走的是完全同一条路：两个项目各有 release `v0.1.0`，cpp 的部署记录是 #12 staging、#13 production，`deploy:*` 任务的输出就是应用自己打印的 `hello, staging! (v0.1.0, staging)` / `hello, production! (v0.1.0, production)`。

```text
#109  release              release  success
#108  deploy:production    deploy   success
#107  deploy:staging       deploy   success
#106  verify               verify   success
#105  test                 test     success
#104  build                build    success
```

三个实现约束都是这一路踩出来的：

- **`release:` 不能挂在跑业务语言的任务上**（Rust / Java / C++ 都一样）。Runner 会在任务自己的镜像里执行 `step_release`，调 `glab` 或 `release-cli`，而 `rust:1.92-slim`、`maven:3.9-eclipse-temurin-17`、`linux-dev:ubuntu20` 三个镜像里既没有 `glab` 也没有 `release-cli`——部署脚本正常打印 `hello, production! (v0.1.0, production)`，任务却判失败：`/usr/bin/bash: line 193: release-cli: command not found`，并附提示 `release-cli will not be supported after 20.0，请改用 glab >= 1.58.0`。模板的解法是把 release 拆成独立任务，镜像换成 `registry.gitlab.com/gitlab-org/release-cli:latest`（90.4 MB，`docker pull` 实测 7.9 秒）。
- **必须挡住 tag 触发的第二条流水线**。Release 会创建 `v0.1.0` 这样的 tag，而 tag 默认也会起一条流水线，所以模板顶部有 `workflow: rules`：`$CI_COMMIT_TAG` → `when: never`，只放 `$CI_COMMIT_BRANCH == "main"`。
- **版本号两处一起改，`--locked` 替你把关**。`APP_VERSION`（CI 变量，决定 tag 名）与 `Cargo.toml` 的 `[package] version` 由 build 任务里一行 `grep -q "^version = \"${APP_VERSION}\""` 对齐；改了版本号还必须重新生成 `Cargo.lock`，否则 `--locked` 直接拦下：`error: the lock file /builds/root/rust-hello/Cargo.lock needs to be updated but --locked was passed to prevent this`。`cargo generate-lockfile --offline` 之后重推即绿。

回滚：GitLab 18.8 **没有**回滚 REST 端点（探测 `POST /projects/3/deployments/4/rollback` → `{"error":"404 Not Found"}`），Environments 页上那颗 Rollback 按钮本质就是重跑对应那次部署的任务。用 API 做同一件事：

```bash
curl -X POST -H "PRIVATE-TOKEN: $(cat ~/gitlab-docker/dev-env-token)" \
  http://gitlab.127.0.0.1.nip.io:8929/api/v4/projects/3/jobs/96/retry   # v0.1.0 那次生产部署
```

实测产生新的部署记录 #9（sha 回到 `090088a`），任务输出 `hello, production! (v0.1.0, production)`。`artifacts.expire_in: 1 week` 就是为了让旧部署任务重跑时还能取到那条流水线的产物——产物一过期回滚就会失败。

一轮演示留下的记录（Deployments / Releases 页可见）：

```text
releases:    v0.2.0  Deployed from pipeline 43 of a058dc7c.
             v0.1.0  Deployed from pipeline 41 of 090088a0.
deployments: #4 production sha=090088a success   v0.1.0 首发
             #8 production sha=a058dc7 success   v0.2.0
             #9 production sha=090088a success   回滚到 v0.1.0
```

页面（用 IP 地址是因为内置浏览器打不开 nip.io 域名，Java / C++ 把项目名换掉即可）：

- <http://127.0.0.1:8929/root/rust-hello/-/pipelines>、<http://127.0.0.1:8929/root/rust-hello/-/environments>、<http://127.0.0.1:8929/root/rust-hello/-/releases>
- <http://127.0.0.1:8929/root/java-hello/-/pipelines>、<http://127.0.0.1:8929/root/cpp-hello/-/pipelines>

推一份新的样例项目（`rust-hello` / `java-hello` / `cpp-hello` 通用，改 `NAME` 即可）：

```bash
TOKEN=$(cat ~/gitlab-docker/dev-env-token)
NAME=rust-hello

curl -s -X POST -H "PRIVATE-TOKEN: $TOKEN" -H "Content-Type: application/json" \
  -d "{\"name\":\"$NAME\",\"path\":\"$NAME\",\"namespace_id\":1,\"visibility\":\"private\",\"default_branch\":\"main\",\"initialize_with_readme\":false}" \
  http://gitlab.127.0.0.1.nip.io:8929/api/v4/projects

DST=~/gitlab-docker/projects/$NAME
mkdir -p "$DST" && cp -R examples/$NAME/. "$DST/"
git init -q -b main "$DST"
git -C "$DST" remote add origin http://gitlab.127.0.0.1.nip.io:8929/root/$NAME.git
git -C "$DST" add -A && git -C "$DST" commit -q -m "feat: $NAME hello world with GitLab CI"
git -C "$DST" -c http.extraHeader="Authorization: Basic $(printf 'oauth2:%s' "$TOKEN" | openssl base64 -A)" \
  push -q origin HEAD:refs/heads/main
```

`gitlab-ci.sh` 不认识这几个项目（它只管 `ci-demo`），重复执行脚本不会重置它们；改模板就改 `examples/<name>/`，再 `cp` 到工作副本重新推送。三份样例都自带 `.gitignore`（`/target/`、`/.cargo/`、`/.m2/`、`/build/`），重建工作副本时直接 `rm -rf "$DST"` 再 `cp`，本机编译产物就不会被提交进去。

## 脚本在本机会写什么

- `~/gitlab-docker/{config,logs,data,runner-config,projects}`：GitLab 配置、日志、数据、runner 注册、工作副本（`projects/` 下现在有 `ci-demo`、`rust-hello`、`java-hello`、`cpp-hello`）；
- `~/gitlab-docker/dev-env-token`（600）：脚本自用的 30 天 API token；
- `~/gitlab-docker/config/dev-env-token.rb`：签发上面 token 的 Rails 脚本，由容器读取执行。

脚本不删除数据；唯一会删的是 GitLab 里状态为 `never_contacted`（从未连上过、无法自愈）的同名 runner 记录，删掉后重新注册。

脚本之外，这一轮手工动过两处，都在 `~/gitlab-docker` 里：

- `runner-config/config.toml` 的 `[runners.docker]` 加了 `pull_policy = "if-not-present"`（见 Rust 一节，改动前后对比见那条里的 trace），生效需要 `docker restart gitlab-runner`；
- root 的 UI 密码换成了一个仅本机测试用的简单密码（`gitlab-ci.sh` 不管密码，这是当时手工设的；要改回去用「访问方式」里的 Rails 控制台重设即可）。

除这两处以外，`~/gitlab-docker` 里没有别的手工改动；三份样例的源文件在本仓库 `examples/` 下，本文档就是仓库根目录的 `README.md`。

## 常见问题

- **job 在 `Getting source from Git repository` 阶段报 `HTTP 500`**：GitLab 长时间关机后，动态分区表没有提前建出当月分区，Rails 写库时抛 `PG::CheckViolation: no partition of relation "project_daily_statistics" found for row`（日志在 `<dir>/logs/gitlab-rails/production.log`）。补一次负责建分区的定时任务即可，只新增未来的分区、不动已有数据：

  ```bash
  docker exec gitlab gitlab-rails runner 'Database::PartitionManagementWorker.perform_async'
  ```

  然后重跑 `gitlab-ci.sh`：脚本对上一次失败的流水线会新起一条，而不是复述旧结果。
- **UI 登录报 `422: The change you requested was rejected`**：不是密码错。日志里会是 `ActionController::InvalidAuthenticityToken`，原因是这个标签页的 CSRF token 已过期——最常见的触发点是标签页在改密码之前打开（改密码会撤销全部会话并轮换 csrf secret），或者浏览器没把 `_gitlab_session` cookie 带回来。关掉旧标签页重新打开登录页即可；`http://127.0.0.1:8929` 和 `http://gitlab.127.0.0.1.nip.io:8929` 是两个不同的 cookie 域，别在两者之间来回切。Qoder 内置浏览器打不开 nip.io 域名，用 IP 地址登录是可以的（实测 `POST /users/sign_in` 返回 302）。
- **一直停在 `waiting for GitLab`**：`docker logs -f gitlab` 看 reconfigure 是否报错，日志也在 `<dir>/logs/reconfigure/`。改过 `--port`/`--host` 后首启会重跑 reconfigure。
- **任务长期 `created`/`pending`**：多半是 runner 不在线或 `tags` 对不上。`gitlab-ci.sh status` 确认 runner 状态，必要时 `docker exec gitlab-runner gitlab-runner verify`。
- **job 卡在准备镜像、或拉镜像超时**：现在这台 runner 的 `[runners.docker]` 里已经写了 `pull_policy = "if-not-present"`（2026-10-27 加的，见「跑 Rust / Java / C++ 项目」一节），本地有镜像就不访问 registry，`linux-dev:ubuntu20` 这类本机自建镜像才能用；如果又出现 trace 里的 `Pulling docker image …`，说明那一行被删了或者 runner 没重启（`docker restart gitlab-runner`）。常用镜像提前 `docker pull` 好即可。
- **端口被占用**：`--port`、`--ssh-port` 换一个，随后 reconfigure 会自动跟上。
- **彻底重置**：`gitlab-ci.sh down` 后手动删除 `<dir>/config` 与 `<dir>/data`。这一步不可逆，会丢掉里面的项目与提交历史。

## 与之前手工部署的关系

本目录沿用 `~/gitlab-docker` 的数据，但把 `external_url` 从 `http://gitlab:8929`（浏览器打不开）换成了 `http://gitlab.127.0.0.1.nip.io:8929`。旧 `runner-config/config.toml` 里注册的 runner 仍然有效，因为 compose 在 `gitlab-net` 上保留了 `gitlab` 这个服务别名，脚本会直接复用它而不重复注册。想让 runner 注册也交给脚本管理，就删掉该 `config.toml`、在 UI 里删掉旧 runner，再跑一次 `gitlab-ci.sh`。
