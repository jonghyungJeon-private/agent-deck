import Foundation
import Darwin

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "pid",
   let pid = Int32(CommandLine.arguments[2]) {
    var kp = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &kp, &size, nil, 0) == 0, size > 0 else { exit(1) }
    print(Double(kp.kp_proc.p_starttime.tv_sec) + Double(kp.kp_proc.p_starttime.tv_usec) / 1_000_000)
    exit(0)
}

// 채널은 환경에서만 받는다. 실제 앱의 기본 디버그 채널에는 절대로 보내지 않는다.
guard let channel = ProcessInfo.processInfo.environment["AGENTDECK_DEBUG_NAME"],
      channel.hasPrefix("dev.agentdeck.video.20261019.run-"),
      CommandLine.arguments.count == 2 else {
    fatalError("source video/scripts/env.sh 후 post '<명령>' 으로 실행하세요")
}
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name(channel), object: CommandLine.arguments[1],
    userInfo: nil, deliverImmediately: true)
