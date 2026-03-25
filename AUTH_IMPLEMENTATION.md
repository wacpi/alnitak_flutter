# 用户认证系统实现文档

## 实现概述

本文档记录了 Alnitak Flutter 应用的用户认证系统实现，包括注册、登录、用户信息管理等完整功能。

## 与 Web（Nuxt）阶段 B / 后端双栈对齐

- **移动端不走浏览器 HttpOnly Cookie**：Flutter 使用 **JSON 响应中的 `token` / `refreshToken`**，通过 Dio 在请求头携带 `Authorization`，与当前后端 **双栈** 契约兼容（PC 侧重 Cookie + SSR，App 侧重 Bearer + body）。
- **`POST /api/v1/auth/updateToken`**：服务端可能在轮换会话时返回 **新的** `refreshToken`；客户端必须在刷新成功后 **持久化新 refresh**（见下文「Refresh 轮换」与 `TokenManager.updateToken`），否则下一轮刷新会失败。
- **`POST /api/v1/auth/logout`**：后端为 **公开路由**，仅凭 body 中的 `refreshToken` 即可吊销会话；**access 已过期时无需也不应强依赖 `Authorization`**，仅发 refresh 即可。

## 文件结构

```
lib/
├── models/
│   ├── auth_models.dart         # 认证相关数据模型
│   └── user_model.dart          # 用户信息数据模型
├── services/
│   ├── auth_service.dart        # 认证服务
│   └── user_service.dart        # 用户服务
├── utils/
│   ├── http_client.dart         # Dio + 刷新拦截器（含 refresh 轮换持久化）
│   └── token_manager.dart       # Token 持久化与 updateToken(refreshToken:)
└── pages/
    ├── login_page.dart          # 登录页面
    ├── register_page.dart       # 注册页面
    └── profile_page.dart        # 个人中心页面（已更新）
```

---

## 一、数据模型

### 1. 认证模型 ([auth_models.dart](lib/models/auth_models.dart))

#### LoginResponse - 登录响应
```dart
class LoginResponse {
  final String token;           // 访问令牌（1小时有效期）
  final String refreshToken;    // 刷新令牌（7天有效期）
}
```

#### RegisterRequest - 注册请求
```dart
class RegisterRequest {
  final String email;
  final String password;
  final String code;            // 邮箱验证码
}
```

#### LoginRequest - 密码登录请求
```dart
class LoginRequest {
  final String email;
  final String password;
  final String? captchaId;      // 可选的人机验证ID
}
```

#### EmailLoginRequest - 邮箱验证码登录请求
```dart
class EmailLoginRequest {
  final String email;
  final String code;
  final String? captchaId;
}
```

#### ModifyPasswordRequest - 修改密码请求
```dart
class ModifyPasswordRequest {
  final String email;
  final String password;
  final String code;
  final String? captchaId;
}
```

### 2. 用户模型 ([user_model.dart](lib/models/user_model.dart))

#### UserBaseInfo - 用户基础信息
```dart
class UserBaseInfo {
  final int uid;                // 用户ID
  final String name;            // 用户名
  final String sign;            // 个性签名
  final String email;           // 邮箱
  final String phone;           // 手机号
  final int status;             // 状态
  final String avatar;          // 头像URL
  final int gender;             // 性别 (0=未知, 1=男, 2=女)
  final String spaceCover;      // 空间封面
  final String birthday;        // 生日
  final DateTime createdAt;     // 创建时间
}
```

#### UserInfo - 完整用户信息
```dart
class UserInfo {
  final UserBaseInfo userInfo;
  final BanInfo? ban;           // 封禁信息（仅在被封禁时返回）
}
```

#### BanInfo - 封禁信息
```dart
class BanInfo {
  final String reason;          // 封禁原因
  final DateTime bannedUntil;   // 封禁结束时间
}
```

#### EditUserInfoRequest - 编辑用户信息请求
```dart
class EditUserInfoRequest {
  final String avatar;
  final String name;
  final int? gender;
  final String birthday;
  final String? sign;
  final String spaceCover;
}
```

---

## 二、服务层

### 1. 认证服务 ([auth_service.dart](lib/services/auth_service.dart))

#### 核心功能

**用户注册**
```dart
Future<bool> register({
  required String email,
  required String password,
  required String code,
})
```
- 接口: `POST /api/v1/auth/register`
- 返回: 注册成功返回 true

**账号密码登录**
```dart
Future<LoginResponse?> login({
  required String email,
  required String password,
  String? captchaId,
})
```
- 接口: `POST /api/v1/auth/login`
- 返回: 登录成功返回 LoginResponse
- 异常: 连续失败3次后抛出"需要人机验证"

**邮箱验证码登录**
```dart
Future<LoginResponse?> loginWithEmail({
  required String email,
  required String code,
  String? captchaId,
})
```
- 接口: `POST /api/v1/auth/login/email`
- 返回: 登录成功返回 LoginResponse

**更新 Token**
```dart
Future<String?> updateToken()
```
- 接口: `POST /api/v1/auth/updateToken`
- 功能: 使用本地 `refreshToken` 获取新的 access；若响应 `data` 中含 **`refreshToken`（服务端轮换）**，会一并写入 `TokenManager`
- 返回: 新的 access token，失败返回 null

**退出登录**
```dart
Future<bool> logout()
```
- 接口: `POST /api/v1/auth/logout`
- 功能: 使用 `refreshToken` 通知服务端吊销会话，并清除本地存储
- 说明: 无 `refreshToken` 时仅清本地；**仅有 refresh、access 已空** 时请求 **不携带** `Authorization`；有 access 时仍可附带，与后端公开 logout 语义一致

**修改密码**
```dart
Future<bool> resetPasswordCheck({required String email, String? captchaId})
Future<bool> modifyPassword({
  required String email,
  required String password,
  required String code,
  String? captchaId,
})
```

#### Token 管理（[token_manager.dart](lib/utils/token_manager.dart)）

**存储机制**
- 使用 `shared_preferences` 对 access / refresh 做混淆持久化
- Access 有效期约 1 小时；Refresh 约 7 天（以后端策略为准）

**核心方法（摘要）**
```dart
Future<void> saveTokens({required String token, required String refreshToken})
/// 刷新后更新 access；[refreshToken] 非空时写入新 refresh（与服务端轮换对齐）
Future<void> updateToken(String token, {String? refreshToken})
Future<void> clearTokens()
String? get token
String? get refreshToken
bool get isLoggedIn
```

**Refresh 轮换**
- [http_client.dart](lib/utils/http_client.dart) 中 `HttpClient.refreshToken()` 与 `AuthInterceptor` 触发刷新时，若 `data['refreshToken']` 存在，会调用 `updateToken(..., refreshToken: newRefresh)`，避免只更新 access 导致旧 refresh 失效后无法续期。

### 2. 用户服务 ([user_service.dart](lib/services/user_service.dart))

#### 核心功能

**获取用户基础信息**
```dart
Future<UserBaseInfo?> getUserBaseInfo(int userId)
```
- 接口: `GET /api/v1/user/getUserBaseInfo?userId={userId}`
- 权限: 无需登录
- 用途: 查看其他用户的公开信息

**获取个人用户信息**
```dart
Future<UserInfo?> getUserInfo()
```
- 接口: `GET /api/v1/user/getUserInfo`
- 权限: 需要登录（Authorization header）
- 返回: 当前登录用户的完整信息

**编辑个人信息**
```dart
Future<bool> editUserInfo({
  required String avatar,
  required String name,
  int? gender,
  required String birthday,
  String? sign,
  required String spaceCover,
})
```
- 接口: `PUT /api/v1/user/editUserInfo`
- 权限: 需要登录

---

## 三、UI 页面

### 1. 登录页面 ([login_page.dart](lib/pages/login_page.dart))

#### 功能特性

**双Tab设计**
- Tab 1: 密码登录
- Tab 2: 验证码登录

**密码登录**
- 邮箱输入（支持格式验证）
- 密码输入（支持显示/隐藏切换）
- 登录按钮（加载状态）
- 注册链接

**验证码登录**
- 邮箱输入
- 验证码输入 + "获取验证码"按钮
- 登录按钮
- 注册链接

**输入验证**
```dart
bool _isValidEmail(String email) {
  return RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$').hasMatch(email);
}
```

**错误处理**
- 连续登录失败3次提示"需要人机验证"
- 网络错误提示
- 空字段验证

**导航**
- 登录成功返回 `true`
- 跳转到注册页面

#### UI 截图说明

```
┌─────────────────────────────┐
│         登录            [X] │
├─────────────────────────────┤
│  密码登录  │  验证码登录    │
├─────────────────────────────┤
│                             │
│   📧 邮箱                   │
│   ┌─────────────────────┐  │
│   │ 请输入邮箱           │  │
│   └─────────────────────┘  │
│                             │
│   🔒 密码                   │
│   ┌─────────────────────┐  │
│   │ 请输入密码          👁│  │
│   └─────────────────────┘  │
│                             │
│   ┌─────────────────────┐  │
│   │      登录           │  │
│   └─────────────────────┘  │
│                             │
│   还没有账号？[立即注册]    │
│                             │
└─────────────────────────────┘
```

### 2. 注册页面 ([register_page.dart](lib/pages/register_page.dart))

#### 功能特性

**注册表单**
- 邮箱输入
- 密码输入（至少6位）
- 确认密码输入
- 验证码输入 + "获取验证码"按钮
- 注册按钮

**输入验证**
- 邮箱格式验证
- 密码长度验证（≥6位）
- 密码一致性验证
- 非空验证

**错误提示**
```dart
if (password != confirmPassword) {
  _showMessage('两次输入的密码不一致');
  return;
}
```

**导航**
- 注册成功后返回登录页面
- "返回登录"链接

#### UI 截图说明

```
┌─────────────────────────────┐
│      ← 注册                 │
├─────────────────────────────┤
│                             │
│   📧 邮箱                   │
│   ┌─────────────────────┐  │
│   │ 请输入邮箱           │  │
│   └─────────────────────┘  │
│                             │
│   🔒 密码                   │
│   ┌─────────────────────┐  │
│   │ 请输入密码（至少6位）👁│  │
│   └─────────────────────┘  │
│                             │
│   🔒 确认密码               │
│   ┌─────────────────────┐  │
│   │ 请再次输入密码       👁│  │
│   └─────────────────────┘  │
│                             │
│   ✅ 验证码                 │
│   ┌───────────┬─────────┐  │
│   │ 请输入验证码│获取验证码│  │
│   └───────────┴─────────┘  │
│                             │
│   ┌─────────────────────┐  │
│   │      注册           │  │
│   └─────────────────────┘  │
│                             │
│   已有账号？[返回登录]      │
│                             │
└─────────────────────────────┘
```

### 3. 个人中心页面 ([profile_page.dart](lib/pages/profile_page.dart)) - 已更新

#### 功能更新

**状态管理**
```dart
UserBaseInfo? _userInfo;        // 用户信息
bool _isLoggedIn = false;       // 登录状态
bool _isLoading = true;         // 加载状态
```

**生命周期**
```dart
@override
void initState() {
  super.initState();
  _loadUserData();  // 自动加载用户数据
}
```

#### 用户数据加载流程

```dart
Future<void> _loadUserData() async {
  // 1. 检查登录状态
  final isLoggedIn = await _authService.isLoggedIn();

  if (isLoggedIn) {
    // 2. 获取用户信息
    final userInfo = await _userService.getUserInfo();

    if (userInfo != null) {
      // 3. 更新UI
      setState(() => _userInfo = userInfo.userInfo);
    } else {
      // 4. Token过期，尝试刷新
      final newToken = await _authService.updateToken();

      if (newToken != null) {
        // 5. 重试获取用户信息
        final retryUserInfo = await _userService.getUserInfo();
        setState(() => _userInfo = retryUserInfo?.userInfo);
      } else {
        // 6. Token失效，清除登录状态
        setState(() => _isLoggedIn = false);
      }
    }
  }
}
```

#### UI 状态

**加载中状态**
- 显示 CircularProgressIndicator

**未登录状态**
```
┌─────────────────────────────┐
│          我的          [🔑] │
├─────────────────────────────┤
│                             │
│         ┌─────┐             │
│         │     │             │
│         │  👤 │             │
│         └─────┘             │
│                             │
│          未登录              │
│                             │
│      [  立即登录  ]         │
│                             │
└─────────────────────────────┘
```

**已登录状态**
```
┌─────────────────────────────┐
│          我的          [🚪] │
├─────────────────────────────┤
│                             │
│         ┌─────┐             │
│         │     │  (头像)     │
│         │ 😊  │             │
│         └─────┘             │
│                             │
│          用户名              │
│       UID: 123456           │
│      这是我的个性签名        │
│                             │
└─────────────────────────────┘
```

#### 新增功能

**AppBar 动态按钮**
```dart
actions: [
  if (_isLoggedIn)
    IconButton(
      icon: const Icon(Icons.logout),
      onPressed: _handleLogout,
    )
  else
    IconButton(
      icon: const Icon(Icons.login),
      onPressed: _navigateToLogin,
    ),
],
```

**退出登录确认**
```dart
Future<void> _handleLogout() async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('确认退出'),
      content: const Text('确定要退出登录吗？'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
        TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('退出')),
      ],
    ),
  );

  if (confirmed == true) {
    await _authService.logout();
    setState(() {
      _isLoggedIn = false;
      _userInfo = null;
    });
  }
}
```

**登录成功回调**
```dart
Future<void> _navigateToLogin() async {
  final result = await Navigator.push(
    context,
    MaterialPageRoute(builder: (context) => const LoginPage()),
  );

  // 如果登录成功，刷新用户数据
  if (result == true) {
    _loadUserData();
  }
}
```

---

## 四、API 接口文档

### 基础信息

- **Base URL**: `http://anime.ayypd.cn:3000`
- **Content-Type**: `application/json`
- **Authorization**: `Bearer {token}` (需要登录的接口)

### 1. 认证接口

#### 注册
```http
POST /api/v1/auth/register
Content-Type: application/json

{
  "email": "user@example.com",
  "password": "password123",
  "code": "123456"
}

Response:
{
  "code": 200,
  "data": null,
  "msg": "ok"
}
```

#### 密码登录
```http
POST /api/v1/auth/login
Content-Type: application/json

{
  "email": "user@example.com",
  "password": "password123",
  "captchaId": "optional-captcha-id"
}

Response (成功):
{
  "code": 200,
  "data": {
    "token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...",
    "refreshToken": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9..."
  },
  "msg": "ok"
}

Response (需要验证):
{
  "code": -1,
  "msg": "需要人机验证"
}
```

#### 邮箱验证码登录
```http
POST /api/v1/auth/login/email
Content-Type: application/json

{
  "email": "user@example.com",
  "code": "123456",
  "captchaId": "optional-captcha-id"
}

Response:
{
  "code": 200,
  "data": {
    "token": "...",
    "refreshToken": "..."
  },
  "msg": "ok"
}
```

#### 更新 Token
说明: 响应 `data.refreshToken` 在服务端轮换时出现新值，须持久化；未轮换时字段可省略或与旧值相同。

```http
POST /api/v1/auth/updateToken
Content-Type: application/json

{
  "refreshToken": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9..."
}
```

成功响应示例：

```json
{
  "code": 200,
  "data": {
    "token": "new-access-token-here",
    "refreshToken": "new-refresh-when-rotated-or-omit"
  },
  "msg": "ok"
}
```

失效响应示例：

```json
{
  "code": 2000,
  "msg": "token失效错误"
}
```

#### 退出登录
- `Authorization` **可选**：access 仍有效时可附带；仅有 refresh、access 已过期时只发 body 即可。

```http
POST /api/v1/auth/logout
Content-Type: application/json

{
  "refreshToken": "..."
}
```

响应示例：

```json
{
  "code": 200,
  "data": null,
  "msg": "ok"
}
```

### 2. 用户接口

#### 获取用户基础信息
```http
GET /api/v1/user/getUserBaseInfo?userId=123

Response:
{
  "code": 200,
  "data": {
    "uid": 123,
    "name": "用户名",
    "sign": "个性签名",
    "email": "user@example.com",
    "phone": "",
    "status": 1,
    "avatar": "https://...",
    "gender": 1,
    "spaceCover": "https://...",
    "birthday": "2000-01-01",
    "createdAt": "2024-01-01T00:00:00Z"
  },
  "msg": "ok"
}
```

#### 获取个人信息
```http
GET /api/v1/user/getUserInfo
Authorization: Bearer {token}
Content-Type: application/json

Response (正常):
{
  "code": 200,
  "data": {
    "userInfo": {
      "uid": 123,
      "name": "用户名",
      ...
    },
    "ban": null
  },
  "msg": "ok"
}

Response (被封禁):
{
  "code": 200,
  "data": {
    "userInfo": {...},
    "ban": {
      "reason": "违规操作",
      "bannedUntil": "2024-12-31T23:59:59Z"
    }
  },
  "msg": "ok"
}
```

#### 编辑个人信息
```http
PUT /api/v1/user/editUserInfo
Authorization: Bearer {token}
Content-Type: application/json

{
  "avatar": "https://...",
  "name": "新用户名",
  "gender": 1,
  "birthday": "2000-01-01",
  "sign": "新签名",
  "spaceCover": "https://..."
}

Response:
{
  "code": 200,
  "data": null,
  "msg": "ok"
}
```

---

## 五、安全性考虑

### 1. Token 管理

**存储安全**
- Token 存储在 `shared_preferences`（加密存储）
- 应用关闭后 token 持久化保存
- 退出登录时立即清除

**自动刷新机制**
- `HttpClient` 的 `AuthInterceptor` 在收到 `code == 3000`（access 过期）时会调用 `refreshToken()`，成功后若响应含新 **refresh** 会一并写入 `TokenManager`（与后端轮换策略一致）。
- 业务侧亦可调用 `AuthService.updateToken()`，行为相同。

```dart
// 在 _loadUserData 等场景中处理 access 过期后的手动刷新
if (userInfo == null) {
  final newToken = await _authService.updateToken();
  if (newToken != null) {
    // 重试请求
  } else {
    // Token 失效，要求重新登录
  }
}
```

### 2. 输入验证

**邮箱格式验证**
```dart
bool _isValidEmail(String email) {
  return RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$').hasMatch(email);
}
```

**密码强度要求**
- 最小长度: 6位
- 建议: 可增加复杂度要求（大小写、数字、特殊字符）

**防暴力破解**
- 连续登录失败3次触发人机验证
- captchaId 参数支持

### 3. 网络安全

**HTTPS 推荐**
- 当前: `http://anime.ayypd.cn:3000`
- 生产环境建议: `https://...`

**请求拦截器**
- 使用 Dio 的 RetryInterceptor（已配置）
- 自动重试失败的请求
- 超时配置: 15s 连接超时, 30s 接收超时

---

## 六、待实现功能

### 1. 验证码功能

**发送验证码接口**
- 注册验证码
- 登录验证码
- 修改密码验证码

**倒计时功能**
```dart
// TODO: 实现发送验证码后的60秒倒计时
int _countdown = 60;
Timer? _timer;

void _startCountdown() {
  _timer = Timer.periodic(Duration(seconds: 1), (timer) {
    if (_countdown == 0) {
      timer.cancel();
      setState(() => _countdown = 60);
    } else {
      setState(() => _countdown--);
    }
  });
}
```

### 2. 人机验证

**Captcha 集成**
- 显示验证码图片
- 验证用户输入
- 获取 captchaId

### 3. 第三方登录

**OAuth 登录**
- 微信登录
- QQ登录
- GitHub登录

### 4. 密码找回

**完整流程**
```dart
// 1. 验证邮箱
await _authService.resetPasswordCheck(email: email);

// 2. 发送验证码

// 3. 验证码验证

// 4. 修改密码
await _authService.modifyPassword(
  email: email,
  password: newPassword,
  code: code,
);
```

### 5. 个人资料编辑

**编辑页面**
- 头像上传
- 用户名修改
- 个性签名编辑
- 生日设置
- 空间封面上传

**图片上传服务**
```dart
// TODO: 实现图片上传
Future<String?> uploadImage(File imageFile) async {
  // 返回图片URL
}
```

---

## 七、错误处理

### 常见错误码

| Code | 含义 | 处理方式 |
|------|------|----------|
| 200 | 成功 | 正常处理 |
| -1 | 需要人机验证 | 显示验证码 |
| 2000 | Token失效 | 刷新token或重新登录 |
| 401 | 未授权 | 跳转登录页 |
| 403 | 禁止访问 | 显示权限错误 |
| 500 | 服务器错误 | 显示错误提示 |

### 错误处理示例

```dart
try {
  final response = await _authService.login(...);
  if (response != null) {
    // 登录成功
  } else {
    _showMessage('登录失败，请检查邮箱和密码');
  }
} catch (e) {
  if (e.toString().contains('需要人机验证')) {
    // 显示验证码
  } else {
    _showMessage('登录失败：${e.toString()}');
  }
}
```

---

## 八、测试清单

### 功能测试

- [ ] 用户注册
  - [ ] 有效邮箱注册成功
  - [ ] 无效邮箱格式提示
  - [ ] 密码长度验证
  - [ ] 密码不一致提示
  - [ ] 验证码错误提示

- [ ] 密码登录
  - [ ] 正确邮箱密码登录成功
  - [ ] 错误密码提示
  - [ ] 连续失败3次触发验证
  - [ ] Token 正确存储

- [ ] 验证码登录
  - [ ] 验证码正确登录成功
  - [ ] 验证码错误提示

- [ ] 个人中心
  - [ ] 未登录显示"立即登录"按钮
  - [ ] 已登录显示用户信息
  - [ ] 头像正确加载
  - [ ] UID 显示正确
  - [ ] 个性签名显示（如有）

- [ ] 退出登录
  - [ ] 确认对话框显示
  - [ ] 退出后清除用户信息
  - [ ] Token 清除成功
  - [ ] 返回未登录状态

- [ ] Token 刷新
  - [ ] Token 过期自动刷新
  - [ ] RefreshToken 失效跳转登录

### UI 测试

- [ ] 登录页面
  - [ ] Tab切换流畅
  - [ ] 密码显示/隐藏切换
  - [ ] 加载状态显示
  - [ ] 跳转注册页面

- [ ] 注册页面
  - [ ] 表单验证提示
  - [ ] 返回登录页面
  - [ ] 验证码按钮状态

- [ ] 个人中心
  - [ ] 加载动画显示
  - [ ] 登录/退出按钮切换
  - [ ] 用户信息正确渲染

### 异常测试

- [ ] 网络异常
  - [ ] 无网络提示
  - [ ] 超时重试
  - [ ] 请求失败提示

- [ ] 数据异常
  - [ ] 空数据处理
  - [ ] 无效数据提示
  - [ ] API错误码处理

---

## 九、性能优化

### 1. 缓存策略

**本地缓存**
```dart
// 缓存用户信息，避免重复请求
class UserCache {
  static UserBaseInfo? _cachedUser;
  static DateTime? _cacheTime;

  static bool isCacheValid() {
    if (_cacheTime == null) return false;
    return DateTime.now().difference(_cacheTime!) < Duration(minutes: 5);
  }
}
```

### 2. 请求优化

**请求去重**
```dart
// 避免同时发起多个相同请求
Future<T>? _ongoingRequest;

Future<T> _request() async {
  if (_ongoingRequest != null) {
    return _ongoingRequest!;
  }

  _ongoingRequest = _httpClient.dio.get(...);
  final result = await _ongoingRequest!;
  _ongoingRequest = null;
  return result;
}
```

### 3. UI 优化

**骨架屏**
```dart
// 替代 CircularProgressIndicator
if (_isLoading) {
  return Shimmer.fromColors(
    baseColor: Colors.grey[300]!,
    highlightColor: Colors.grey[100]!,
    child: Container(...),
  );
}
```

---

## 十、总结

### 已实现功能 ✅

1. ✅ 用户注册
2. ✅ 密码登录
3. ✅ 邮箱验证码登录
4. ✅ Token 管理（存储、获取、刷新、清除）
5. ✅ 退出登录
6. ✅ 获取用户信息
7. ✅ 个人中心页面集成
8. ✅ 登录状态管理
9. ✅ 自动 Token 刷新

### 待实现功能 📋

1. 📋 验证码发送功能
2. 📋 人机验证集成
3. 📋 密码找回流程
4. 📋 个人资料编辑页面
5. 📋 头像/图片上传
6. 📋 第三方登录
7. 📋 设置页面
8. 📋 账号安全设置

### 技术亮点 ⭐

1. **单例模式**: AuthService 和 UserService 使用单例模式，确保全局只有一个实例
2. **自动 Token 刷新**: 请求失败时自动尝试刷新 token
3. **状态管理**: 完善的登录状态管理和 UI 状态切换
4. **错误处理**: 完整的错误捕获和用户友好提示
5. **安全性**: Token 安全存储，退出登录清除本地数据
6. **可维护性**: 清晰的代码结构，易于扩展

---

**文档版本**: v1.0
**创建日期**: 2025-01-09
**最后更新**: 2025-01-09
**作者**: Claude Code
