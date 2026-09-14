# 正式版本（release）构建

> 面向 Android。日常开发用 `flutter build apk --debug`，**发布必须用本文的流程**。

## 1. 与 debug 构建的区别

| | debug | release（本文） |
|---|---|---|
| 命令 | `flutter build apk --debug` | `flutter build apk --release` |
| R8 混淆 + 资源压缩 | 关 | **开**（`isMinifyEnabled` / `isShrinkResources` + `proguard-rules.pro`） |
| ABI 分割 | 关 | **开**（arm64-v8a / armeabi-v7a / x86_64 + 全量包） |
| 签名 | debug keystore（自动） | **release keystore（必须显式配置）** |
| 体积（arm64） | 89.9 MB | **22.0 MB** |

体积构成与优化依据见 `docs/build-size-report.md`。

## 2. 为什么必须有 key.properties

`android/app/build.gradle.kts` 对 `assembleRelease` / `bundleRelease` 设了**签名门禁**：

```kotlin
tasks.configureEach {
    if (name == "assembleRelease" || name == "bundleRelease") {
        doFirst {
            if (!keystorePropertiesFile.exists() && !allowDebugSigning) {
                throw GradleException(
                    "Release signing requires android/key.properties; " +
                        "use -Pmusaic.allowDebugSigning=true only for local testing.",
                )
            }
        }
    }
}
```

缺少 `android/key.properties` 时**构建直接失败**——这是刻意设计：避免悄悄产出未签名包，或误用 debug 密钥充当正式版。

> `-Pmusaic.allowDebugSigning=true` **仅供本地测试**，产出的是 **debug 签名**包，
> 不可分发（用户换机升级会因签名不一致而失败）。

## 3. 一次性：生成 release keystore

> ⚠️ **keystore 是应用的签名身份，一旦丢失，已发布的包将无法再升级**（只能换包名重发）。
> 请立即把 `.p12` 与口令备份到安全位置（密码管理器 / 离线介质），**不要**提交进仓库。

```bash
mkdir -p ~/.musaic-signing && chmod 700 ~/.musaic-signing
cd ~/.musaic-signing

# 32 位随机口令
PW=$(python3 -c "import secrets,string; a=string.ascii_letters+string.digits; print(''.join(secrets.choice(a) for _ in range(32)))")
echo "$PW" > .storepass && chmod 600 .storepass

# 生成（RSA 4096 / 有效期 10000 天）
keytool -genkeypair -v \
  -keystore musaic-release.jks -alias musaic \
  -keyalg RSA -keysize 4096 -validity 10000 -storetype JKS \
  -storepass "$PW" -keypass "$PW" \
  -dname "CN=Musaic, OU=Mobile, O=YoisakiKnd, C=CN"

# 迁移到行业标准 PKCS12（消除 keytool 的格式警告）
keytool -importkeystore \
  -srckeystore musaic-release.jks -destkeystore musaic-release.p12 -deststoretype PKCS12 \
  -srcstorepass "$PW" -deststorepass "$PW" \
  -srcalias musaic -destalias musaic -srckeypass "$PW" -destkeypass "$PW" -noprompt
rm -f musaic-release.jks
```

查看证书指纹（用于核对签名身份）：

```bash
keytool -list -v -keystore ~/.musaic-signing/musaic-release.p12 -storepass "$(cat ~/.musaic-signing/.storepass)" -alias musaic
```

## 4. 一次性：配置 key.properties

`android/app/build.gradle.kts` 读取 `rootProject.file("key.properties")`，即 **`android/key.properties`**：

```properties
storePassword=<口令>
keyPassword=<口令>
keyAlias=musaic
storeFile=/绝对路径/musaic-release.p12
```

```bash
chmod 600 android/key.properties
```

该文件已被 `.gitignore`（`android/.gitignore:13` 与根 `.gitignore` 的 `key.properties`、`*.jks`、`*.keystore`）忽略，**切勿提交**。

## 5. 构建正式产物

```bash
flutter pub get
flutter build apk --release
```

产物目录 `build/app/outputs/flutter-apk/`：

| 文件 | 适用 | 参考体积 |
|---|---|---|
| `app-arm64-v8a-release.apk` | 现代真机（首选） | 22.0 MB |
| `app-armeabi-v7a-release.apk` | 老旧 32 位真机 | 19.8 MB |
| `app-x86_64-release.apk` | 模拟器（保留用于验证 release 包） | 23.4 MB |
| `app-release.apk` | 全量包（三 ABI 合一） | 60.6 MB |

Gradle 原始产物在 `build/app/outputs/apk/release/`。

## 6. 验证签名（**必做**）

构建成功 ≠ 签名正确。务必显式校验：

```bash
APKSIGNER=$(ls "$HOME/Library/Android/sdk/build-tools/"*/apksigner | tail -1)
for f in build/app/outputs/flutter-apk/app-*-release.apk build/app/outputs/flutter-apk/app-release.apk; do
  printf '%-46s ' "$(basename "$f")"
  "$APKSIGNER" verify "$f" >/dev/null 2>&1 && echo "SIGNED" || echo "UNSIGNED"
  "$APKSIGNER" verify --print-certs "$f" | grep -m1 'certificate DN'
done
```

期望：每个文件都是 `SIGNED`，且证书 DN 为你的发布身份（**不能**是 `CN=Android Debug`）。

同时确认 release 属性：

```bash
AAPT=$(ls "$HOME/Library/Android/sdk/build-tools/"*/aapt2 | tail -1)
"$AAPT" dump badging build/app/outputs/flutter-apk/app-arm64-v8a-release.apk | grep -E '^package|targetSdk'
"$AAPT" dump xmltree --file AndroidManifest.xml build/app/outputs/flutter-apk/app-arm64-v8a-release.apk | grep -i debuggable
```

第二条应**无输出**（release 包不含 `debuggable` 属性）。

## 7. CI：自动构建正式版本

`.github/workflows/release.yml` 负责正式产物；`.github/workflows/ci.yml` 保持只跑质量门禁与 debug 冒烟，两者互不影响。

**触发条件**：推送 `v*.*.*` 形式的 tag，或手动 `workflow_dispatch`。

**前置：配置 4 个 GitHub Secrets**（仓库 → Settings → Secrets and variables → Actions）：

| Secret | 内容 |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | keystore 文件的 base64 |
| `ANDROID_STORE_PASSWORD` | keystore 口令 |
| `ANDROID_KEY_ALIAS` | 密钥别名（本项目为 `musaic`） |
| `ANDROID_KEY_PASSWORD` | 密钥口令 |

生成 base64（**单行**，macOS 用 `base64 -i`，GNU 用 `base64 -w0`）：

```bash
base64 -i ~/.musaic-signing/musaic-release.p12 | tr -d '\n' | pbcopy   # macOS，直接进剪贴板
```

未配置时 workflow 会**明确报错退出**（不会产出未签名包）。

**发布新版本**：

```bash
# 1) 同步版本号（两处必须一致，由 test/core/app_info_test.dart 守护）
#    pubspec.yaml: version: X.Y.Z+N
#    lib/core/app_info.dart: static const String version = 'X.Y.Z';
# 2) 更新 CHANGELOG.md
git commit -am "chore(release): vX.Y.Z"
git tag -a vX.Y.Z -m "Musaic vX.Y.Z"
git push origin main && git push origin vX.Y.Z
```

tag 推送后 workflow 会：构建 → 校验签名 → 上传 artifact → 把 APK 附到对应的 GitHub Release。

## 8. 常见问题

| 现象 | 原因 / 处理 |
|---|---|
| `Release signing requires android/key.properties` | 缺 `android/key.properties`，或 `storeFile` 路径不存在 |
| `Keystore was tampered with, or password was incorrect` | `storePassword` / `keyPassword` 错误 |
| `Signer #1 certificate DN: CN=Android Debug` | 误用了 `-Pmusaic.allowDebugSigning=true`，不是正式包 |
| 构建成功但 `apksigner verify` 失败 | 产物未签名——检查 `signingConfig` 是否被解析到 release |
| 用户安装时提示签名冲突 | 与已安装版本的签名身份不同；同一应用必须始终使用同一 keystore |
