# Musaic R8 规则。
#
# 目标：只保留真正被反射/序列化用到的成员，其余交给 R8 消除。
# 原则是**尽量少写 keep 规则**——每条 keep 都会削弱优化效果。

# Flutter 引擎与插件注册：通过反射查找 GeneratedPluginRegistrant，
# 被 R8 改名会导致插件全部失效（构建成功但运行崩溃）。
-keep class io.flutter.plugins.GeneratedPluginRegistrant { *; }
-keep class io.flutter.app.** { *; }
-keep class io.flutter.embedding.** { *; }

# audio_service：后台 Service / 前台通知通过系统反射实例化。
-keep class com.ryanheise.audioservice.** { *; }
-keep class com.ryanheise.just_audio.** { *; }

# flutter_inappwebview：JS bridge 通过 @JavascriptInterface 反射调用。
-keepclassmembers class * {
    @android.webkit.JavascriptInterface <methods>;
}

# permission_handler / connectivity_plus 等插件通过注解与反射注册。
-keep class com.baseflow.permissionhandler.** { *; }
-keep class dev.fluttercommunity.plus.connectivity.** { *; }

# Hive 的 TypeAdapter 依赖泛型签名（虽然本项目只存 String，保留以防后续扩展）。
-keepattributes Signature
-keepattributes *Annotation*

# 保留行号，便于线上崩溃栈定位（体积代价极小）。
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile

# Flutter 引擎引用了 Play Core（动态功能模块）的类，但本项目未使用
# 该特性（未依赖 play-core）。这些类在运行时不会被触达，
# 属官方已知情况，抑制警告即可。
-dontwarn com.google.android.play.core.**

# 抑制 R8 对缺失引用类的警告（Flutter 插件常见，属正常情况）。
-dontwarn org.apache.tika.**
-dontwarn javax.**
