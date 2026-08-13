# TestFlight 发布手册(给开发者/律师试用)

## 前提(需要你手动完成的,我无法代做)

### 1. App Store Connect 后台(浏览器操作)
1. 登录 https://appstoreconnect.apple.com (账号 `304471720@qq.com` / team `SP272623JD`)
2. 创建 App:`我的 App → + → 新建 App`
   - 平台: iOS
   - 名称: Hardlaw(或你定的名字)
   - Bundle ID: **com.hardlaw.hardlawApp**(需先在 Identifiers 注册,与 project.yml 的 `bundleIdPrefix: com.hardlaw` 对应)
   - SKU: hardlaw001
3. 填写 App 信息:
   - **隐私政策 URL**(必填,否则无法提交):本项目处理敏感个人信息(身份证/银行流水/聊天记录),需一个公开的隐私政策页面
   - 出口合规:选择"未使用加密"或如实申报
4. 用户管理 → 创建 API Key(用于 CI 上传):
   - 访问级别: App Manager
   - 下载 `.p8` 文件(只下载一次!)并记录 Key ID、Issuer ID

### 2. GitHub Secrets(仓库 Settings → Secrets and variables → Actions)
| Secret 名 | 值 |
|---|---|
| `APPLE_API_KEY` | `.p8` 文件内容(整个文件文本) |
| `APPLE_API_ISSUER` | API Key 的 Issuer ID |
| `APPLE_API_KEY_ID` | API Key 的 10 位 ID |

## 构建流程(已配置好,自动执行)

`push 到 feature/hardlaw-ios 或 main` 时,GitHub Actions 的 `testflight` job 会自动:
1. `xcodegen generate` 生成 Xcode 工程
2. `xcodebuild archive` 构建归档
3. `altool --upload-app` 上传到 TestFlight

**未配置 secrets 时 job 自动跳过**(不影响现有 CI 测试)。

## 提交前注意事项

### 已知待确认项(首次提交前应检查)
- [ ] **隐私政策 URL** 必须可用(App Store Connect 强制)
- [ ] PaddleOCR 真机库已在 git(`ios/HardlawApp/PaddleOCR/lib/libpaddle_api_light_bundled.a`)✅
- [ ] `AutoFillParser.swift` 有未提交本地改动(前序会话遗留)——确认是否应包含
- [ ] 本地 `xcodebuild` 因系统禁用 sandbox-exec 无法构建,**一切构建走 CI**(云端 macos-15 无此问题)

### 律师试用前的合规提示
- App 处理敏感个人信息,建议首次启动弹出**隐私说明**(数据仅本地处理,不联网上传)
- 若未来接云端 LLM,必须先做 PII 脱敏 + 单独同意(见 `docs/llm-routing.md`)

## 首次上传后的步骤
1. TestFlight 构建处理完成后(通常 5-30 分钟),在 App Store Connect → TestFlight → 添加测试员(律师邮箱)
2. 律师用 TestFlight App + 邀请码安装
3. 每次修复后 push 即可自动出新版(需在 CI 手动批准构建或配置自动发布)

## 当前版本
- `MARKETING_VERSION: 0.1.0`,`CURRENT_PROJECT_VERSION: 1`(在 `ios/project.yml`)
- 后续发版递增 `CURRENT_PROJECT_VERSION`
