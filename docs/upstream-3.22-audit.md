# iperf 3.22 升级决策

关联 [Issue #198](https://github.com/gewill/iperf-swift/issues/198)。上游固定为
[`3.22`](https://github.com/esnet/iperf/releases/tag/3.22)，commit
`926bd905501b792bd082d2200d1d1a84aa543e3a`；本地修复基线为 develop
`74354b1d64117f59d98f49c33870957105a547dc`（与已发布 v3.21.19 内容相同）。

## 保留认证实现

上游 RSA 缓冲区与 Base64 长度修复针对旧实现。本项目已改用 EVP 查询输出长度、
严格校验 Base64 字母表和 padding、检查失败返回并清空输出。升级保留这套实现，
`iperf_auth.c` 相对基线只更新上游版权年份，避免重新引入旧 RSA API 或放宽校验。
`IperfConfiguration.publicKey` 与 `privateKey` 必须继续接收 **PEM 文本内容的
Base64 字符串**，不能改成文件路径，也不接受 Base64 编码的路径。两者均从内存
解析；私钥留在服务端，不通过网络发送。`authorizedUsers` 也保持内容输入。
内存解析的安全修复保存在同步补丁中，`sync.sh` 在替换源码前检查两个 setter 仍调用
`load_*key_from_base64`；上游 CLI 明确带 `-path` 的选项继续读文件。

认证兼容性继续通过 CLI 双向互操作及 OAEP / PKCS#1 v1.5 测试约束。ASan 检查
精确容量与超限输入，Swift 测试检查截断、篡改、错误密钥后不产生凭据。
互操作测试删除 Swift 一端的密钥源文件后再认证；另有回归测试用真实有效的
密钥文件，确认 Swift 预检和 C setter 都拒绝路径输入。

## 合并边界

- 重建相对 pristine 3.22 的统一补丁，保留上下文。此前额外 Perl 替换已移入
  补丁，避免同步时静默失配；`sync.sh` 仍保留关键生成结果检查。
- 新增错误写入沿用 `iperf_set_error`，新增 watchdog `sp->done` 写入沿用原子访问。
- TCP socket-option 失败沿用监听 FD 所有权清理；UDP 新失败分支进入既有 cleanup，
  保留 v3.21.19 的固定客户端端口回收修复。
- Swift 非法 DSCP 从 `IEBADTOS` 改为上游 `IEBADDSCP`；TOS 仍使用 `IEBADTOS`。
  新增两个 C 错误码映射。结果模型、回调生命周期、最低系统版本与 OpenSSL 依赖不变。

## 嵌入进程约束

引擎跑在宿主 App 进程里，任何失败都只能结束本次测试，不能终止或卡死宿主。为此在
上游 3.22 之外保留三处补丁：

- `readentropy()` 在 Apple 平台改用 `arc4random_buf()`。3.22 改为每次调用都打开
  `/dev/urandom`，失败时 `iperf_errexit()` 会 `exit(1)`。每个流因此多占一个临时 FD，
  FD 耗尽时宿主进程会被直接终止，而不是得到 `IECREATESTREAM`。改回缓存句柄同样能
  避免逐流 FD，但首次打开失败时仍会退出；`arc4random_buf()` 既不占 FD 也不会失败。
- 看门狗和 `cleanup_server()` 在 cancel/join 工作线程之前先 `shutdown()` TCP 流。
  Darwin 上 `pthread_cancel()` 最多打断一次阻塞的 `sendfile()`（zerocopy 发送）；
  如果这次调用已经发出部分数据，`Nsendfile()` 会再次进入并永久阻塞，join 随之挂住，
  `stop()` 也无法恢复。`shutdown()` 能唤醒阻塞调用，FD 编号则保留到 join 之后才关闭，
  不会被其他代码复用。UDP 流不做 shutdown：它的阻塞调用都能被取消，而 UDP socket 没有
  `SO_NOSIGPIPE`，shutdown 之后再 send 会让宿主进程收到 SIGPIPE。上游的 TEST_END 和
  CLIENT_TERMINATE 处理会先关闭全部流 socket，之后才拆除线程；这两处关闭时把流标为
  done，拆除时跳过这些流，因为 `close()` 已唤醒线程，而该编号可能已被宿主复用。
- `iperf_new_stream()` 失败时，服务端和客户端都由调用方关闭这个尚未进入
  `test->streams` 的 socket，否则每次失败都会留下一个半开连接。

## 验证边界

`Scripts/verify_engine_regressions.sh` 将真实 C 实现包含进测试翻译单元，访问私有
参数解析和 watchdog 路径，不增加生产测试 API。故障注入只用于确定性触发 socket
选项失败和无效 UDP stride。CLI 互操作、定时器和 UDP 首包 TOS 使用真实本地 socket。
子进程设有超时，服务器监听观察不消耗 one-off 连接。

上面三项嵌入约束都有回归检查，撤掉其中任一处修复都会让对应检查失败：
降低 `RLIMIT_NOFILE` 后只留一个 FD 创建流和 cookie；用大于回环缓冲区的块让
zerocopy 发送线程停在 `sendfile()` 中途，分别经看门狗和 `cleanup_server()` 拆除；
TEST_END、CLIENT_TERMINATE 释放的编号被复用后，停止线程不得对其 shutdown；
客户端建流失败后对端必须读到 EOF；嵌入式服务端在奇、偶两种 FD 预算下接受 CLI
客户端，本次测试必须以错误结束，进程正常退出且不残留 FD。

Linux GSO/GRO 和零拷贝平台能力随上游源码同步；Apple 构建与本地 socket 测试不能
替代 Linux 运行验证。具体命令、结果及源码提交记录在升级 PR，本文只保存长期决策。
