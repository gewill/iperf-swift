# iperf 3.22 升级决策

关联 [Issue #198](https://github.com/gewill/iperf-swift/issues/198)。上游固定为
[`3.22`](https://github.com/esnet/iperf/releases/tag/3.22)，commit
`926bd905501b792bd082d2200d1d1a84aa543e3a`；本地修复基线为 develop
`74354b1d64117f59d98f49c33870957105a547dc`（与已发布 v3.21.19 内容相同）。

## 保留认证实现

上游 RSA 缓冲区与 Base64 长度修复针对旧实现。本项目已改用 EVP 查询输出长度、
严格校验 Base64 字母表和 padding、检查失败返回并清空输出。升级保留这套实现，
`iperf_auth.c` 相对基线只更新上游版权年份，避免重新引入旧 RSA API 或放宽校验。
密钥与 authorized-users 仍采用 content-only API；不恢复路径读取。

认证兼容性继续通过 CLI 双向互操作及 OAEP / PKCS#1 v1.5 测试约束。ASan 检查
精确容量与超限输入，Swift 测试检查截断、篡改、错误密钥后不产生凭据。

## 合并边界

- 重建相对 pristine 3.22 的统一补丁，保留上下文。此前额外 Perl 替换已移入
  补丁，避免同步时静默失配；`sync.sh` 仍保留关键生成结果检查。
- 新增错误写入沿用 `iperf_set_error`，新增 watchdog `sp->done` 写入沿用原子访问。
- TCP socket-option 失败沿用监听 FD 所有权清理；UDP 新失败分支进入既有 cleanup，
  保留 v3.21.19 的固定客户端端口回收修复。
- Swift 非法 DSCP 从 `IEBADTOS` 改为上游 `IEBADDSCP`；TOS 仍使用 `IEBADTOS`。
  新增两个 C 错误码映射。结果模型、回调生命周期、最低系统版本与 OpenSSL 依赖不变。

## 验证边界

`Scripts/verify_engine_regressions.sh` 将真实 C 实现包含进测试翻译单元，访问私有
参数解析和 watchdog 路径，不增加生产测试 API。故障注入只用于确定性触发 socket
选项失败和无效 UDP stride。CLI 互操作、定时器和 UDP 首包 TOS 使用真实本地 socket。
子进程设有超时，服务器监听观察不消耗 one-off 连接。

Linux GSO/GRO 和零拷贝平台能力随上游源码同步；Apple 构建与本地 socket 测试不能
替代 Linux 运行验证。具体命令、结果及源码提交记录在升级 PR，本文只保存长期决策。
