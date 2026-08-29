package app.musaic

import com.ryanheise.audioservice.AudioServiceActivity

// audio_service 要求启动 Activity 继承 AudioServiceActivity：
// 向后台媒体服务提供 FlutterEngine，缺失会导致 AudioService.init
// 抛 PlatformException、通知栏/锁屏/媒体键全部失效（模拟器实测定位）。
class MainActivity : AudioServiceActivity()
