可以。下面是一套**直接在你电脑上运行的 EDC 微信小程序基础项目**，不需要 GitHub，也不使用微信云开发。

包含：

- 研究人员账号登录。
- 受试者访视记录列表、搜索。
- 新增、查看、修改记录。
- 前后端数据校验。
- 同一受试者、同一访视防重复。
- 修改原因、修改前后内容留痕。
- 版本冲突检测，避免覆盖他人修改。
- SQLite 本地持久化存储。

这里用“受试者编号、访视、膀胱疼痛 NRS、Qmax、PVR”作为示例字段。**这是用于开发和模拟数据测试的基础版，尚不是经过验证、可直接用于正式临床研究的完整 EDC。**

代码全部贴在下面，按路径创建文件即可。

---

**一、项目结构**

```text
edc-project/
├── server/
│   ├── package.json
│   ├── .env.example
│   ├── server.js
│   └── data/                     # 启动后自动创建
│       └── edc.sqlite            # 自动生成的数据库
│
└── miniprogram/
    ├── project.config.json
    ├── app.js
    ├── app.json
    ├── app.wxss
    ├── utils/
    │   └── request.js
    └── pages/
        ├── login/
        │   ├── login.js
        │   └── login.wxml
        ├── records/
        │   ├── records.js
        │   └── records.wxml
        └── record/
            ├── record.js
            └── record.wxml
```

各页面共用 `app.wxss`，因此不必分别创建页面 WXSS 文件；页面 JSON 也可省略。

运行关系：

```text
微信开发者工具中的小程序
        ↓ HTTP 请求
本机 Node.js：3000 端口
        ↓
本机 SQLite 数据库
```

数据库不会因为关闭小程序或重启后端而清空。登录会话放在后端内存中，重启后需要重新登录。

---

**二、后端代码**

使用 Node.js 24、Express 5 和 better-sqlite3。Express 5 要求 Node.js 18 及以上；better-sqlite3 建议使用仍受支持的 Node.js 版本。[Express.js](https://expressjs.com/en/guide/migrating-5/?utm_source=chatgpt.com)

**1. `server/package.json`**

```json
{
  "name": "local-edc-server",
  "version": "1.0.0",
  "private": true,
  "description": "Local EDC development backend",
  "scripts": {
    "start": "node --env-file=.env server.js"
  },
  "engines": {
    "node": ">=24"
  },
  "dependencies": {
    "better-sqlite3": "^12.0.0",
    "express": "^5.1.0",
    "express-rate-limit": "^8.0.0"
  }
}
```

**2. `server/.env.example`**

复制这个文件，另存为同目录下的 `.env`，再设置密码。

```dotenv
HOST=127.0.0.1
PORT=3000

EDC_USERNAME=researcher
EDC_PASSWORD=请替换为至少12位的自定义密码
```

这里的账号是**本地研究人员账号**，不是微信账号。

**3. `server/server.js`**

```javascript
const express = require("express");
const { rateLimit } = require("express-rate-limit");
const Database = require("better-sqlite3");
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");

const app = express();

app.disable("x-powered-by");
app.use(express.json({ limit: "32kb" }));

const HOST = process.env.HOST || "127.0.0.1";
const PORT = Number(process.env.PORT || 3000);
const USERNAME = process.env.EDC_USERNAME || "researcher";
const PASSWORD = process.env.EDC_PASSWORD || "";

if (
  PASSWORD.length < 12 ||
  PASSWORD.includes("请替换")
) {
  throw new Error("请先在 .env 中设置至少 12 位的 EDC_PASSWORD");
}

// 示例只有一个研究人员账号。
// 密码在启动时计算摘要，比较时使用恒定时间比较。
const passwordSalt = crypto.randomBytes(16);
const passwordHash = crypto.scryptSync(PASSWORD, passwordSalt, 64);

// ---------- 数据库 ----------

const dataDir = path.join(__dirname, "data");
fs.mkdirSync(dataDir, { recursive: true });

const db = new Database(path.join(dataDir, "edc.sqlite"));

db.pragma("journal_mode = WAL");
db.pragma("foreign_keys = ON");
db.pragma("busy_timeout = 5000");

db.exec(`
  CREATE TABLE IF NOT EXISTS records (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    subject_code TEXT NOT NULL,
    visit_code TEXT NOT NULL,
    visit_date TEXT NOT NULL,
    pain_nrs INTEGER NOT NULL CHECK(pain_nrs BETWEEN 0 AND 10),
    qmax REAL,
    pvr REAL,
    notes TEXT NOT NULL DEFAULT '',
    version INTEGER NOT NULL DEFAULT 1,
    created_by TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_by TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    UNIQUE(subject_code, visit_code)
  );

  CREATE TABLE IF NOT EXISTS audit_logs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    record_id INTEGER NOT NULL REFERENCES records(id),
    action TEXT NOT NULL,
    actor TEXT NOT NULL,
    reason TEXT NOT NULL,
    before_json TEXT,
    after_json TEXT NOT NULL,
    created_at TEXT NOT NULL
  );

  CREATE INDEX IF NOT EXISTS idx_audit_record
  ON audit_logs(record_id, id);
`);

function now() {
  return new Date().toISOString();
}

function fail(status, message) {
  const error = new Error(message);
  error.status = status;
  throw error;
}

function publicRecord(row) {
  return {
    id: row.id,
    subjectCode: row.subject_code,
    visitCode: row.visit_code,
    visitDate: row.visit_date,
    painNrs: row.pain_nrs,
    qmax: row.qmax,
    pvr: row.pvr,
    notes: row.notes,
    version: row.version,
    createdBy: row.created_by,
    createdAt: row.created_at,
    updatedBy: row.updated_by,
    updatedAt: row.updated_at
  };
}

function getRecord(id) {
  const row = db.prepare(
    "SELECT * FROM records WHERE id = ?"
  ).get(id);

  if (!row) fail(404, "记录不存在");
  return publicRecord(row);
}

function parseId(value) {
  const id = Number(value);

  if (!Number.isSafeInteger(id) || id <= 0) {
    fail(400, "记录 ID 无效");
  }

  return id;
}

// ---------- 登录及会话 ----------

const sessions = new Map();
const SESSION_TTL = 8 * 60 * 60 * 1000;

setInterval(() => {
  for (const [token, session] of sessions) {
    if (session.expiresAt <= Date.now()) {
      sessions.delete(token);
    }
  }
}, 60 * 1000).unref();

const loginLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  limit: 10,
  standardHeaders: "draft-8",
  legacyHeaders: false,
  message: { message: "登录尝试过多，请 15 分钟后重试" }
});

app.get("/api/health", (req, res) => {
  res.json({ ok: true });
});

app.post("/api/login", loginLimiter, (req, res) => {
  const { username, password } = req.body || {};

  if (
    typeof username !== "string" ||
    typeof password !== "string" ||
    password.length > 256
  ) {
    fail(400, "账号或密码格式错误");
  }

  const inputHash = crypto.scryptSync(password, passwordSalt, 64);
  const passwordMatches = crypto.timingSafeEqual(
    inputHash,
    passwordHash
  );

  if (username !== USERNAME || !passwordMatches) {
    fail(401, "账号或密码错误");
  }

  const token = crypto.randomBytes(32).toString("hex");

  sessions.set(token, {
    username: USERNAME,
    expiresAt: Date.now() + SESSION_TTL
  });

  res.json({
    token,
    username: USERNAME,
    expiresIn: SESSION_TTL / 1000
  });
});

// 后面的 /api 接口均要求登录。
app.use("/api", (req, res, next) => {
  const authorization = req.get("Authorization") || "";
  const token = authorization.startsWith("Bearer ")
    ? authorization.slice(7)
    : "";

  const session = sessions.get(token);

  if (!session || session.expiresAt <= Date.now()) {
    sessions.delete(token);
    return res.status(401).json({
      message: "登录已失效，请重新登录"
    });
  }

  req.actor = session.username;
  req.token = token;
  next();
});

app.post("/api/logout", (req, res) => {
  sessions.delete(req.token);
  res.json({ ok: true });
});

// ---------- 校验 ----------

const visitCodes = new Set(["BASELINE", "W4", "W8"]);

function requiredText(value, label, maxLength) {
  if (typeof value !== "string") {
    fail(400, `${label}格式错误`);
  }

  const text = value.trim();

  if (!text || text.length > maxLength) {
    fail(400, `${label}不能为空，且不能超过 ${maxLength} 字`);
  }

  return text;
}

function numberField(value, label, options = {}) {
  const { required = false, integer = false, max } = options;

  if (
    value === null ||
    value === undefined ||
    (typeof value === "string" && value.trim() === "")
  ) {
    if (required) fail(400, `请填写${label}`);
    return null;
  }

  if (typeof value !== "string" && typeof value !== "number") {
    fail(400, `${label}必须为数字`);
  }

  const number = Number(value);

  if (
    !Number.isFinite(number) ||
    number < 0 ||
    (integer && !Number.isInteger(number)) ||
    (max !== undefined && number > max)
  ) {
    fail(400, `${label}数值无效`);
  }

  return number;
}

function validateRecord(body) {
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    fail(400, "请求体格式错误");
  }

  const subjectCode = requiredText(
    body.subjectCode, "受试者编号", 30
  ).toUpperCase();

  if (!/^[A-Z0-9-]{1,30}$/.test(subjectCode)) {
    fail(400, "受试者编号仅支持字母、数字和短横线");
  }

  if (!visitCodes.has(body.visitCode)) {
    fail(400, "访视类型无效");
  }

  const visitDate = requiredText(body.visitDate, "访视日期", 10);

  if (!/^\d{4}-\d{2}-\d{2}$/.test(visitDate)) {
    fail(400, "日期格式应为 YYYY-MM-DD");
  }

  const date = new Date(`${visitDate}T00:00:00.000Z`);

  if (
    Number.isNaN(date.getTime()) ||
    date.toISOString().slice(0, 10) !== visitDate
  ) {
    fail(400, "访视日期不存在");
  }

  const painNrs = numberField(body.painNrs, "疼痛 NRS", {
    required: true,
    integer: true,
    max: 10
  });

  // 这里仅作数据类型及非负校验。
  // 临床范围核查应按研究方案另行设置。
  const qmax = numberField(body.qmax, "Qmax");
  const pvr = numberField(body.pvr, "PVR");

  const notes = body.notes === undefined ? "" : body.notes;

  if (typeof notes !== "string" || notes.length > 1000) {
    fail(400, "备注不能超过 1000 字");
  }

  return {
    subjectCode,
    visitCode: body.visitCode,
    visitDate,
    painNrs,
    qmax,
    pvr,
    notes: notes.trim()
  };
}

function writeAudit(recordId, action, actor, reason, before, after) {
  db.prepare(`
    INSERT INTO audit_logs (
      record_id, action, actor, reason,
      before_json, after_json, created_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?)
  `).run(
    recordId,
    action,
    actor,
    reason,
    before ? JSON.stringify(before) : null,
    JSON.stringify(after),
    now()
  );
}

// ---------- 接口 ----------

// 列表支持按受试者编号搜索及分页。
app.get("/api/records", (req, res) => {
  const q = String(req.query.q || "").trim().toUpperCase();
  const page = Number(req.query.page || 1);
  const pageSize = 20;

  if (q.length > 30) fail(400, "搜索内容过长");

  if (!Number.isSafeInteger(page) || page < 1 || page > 1000000) {
    fail(400, "页码无效");
  }

  const total = db.prepare(`
    SELECT COUNT(*) AS count
    FROM records
    WHERE instr(subject_code, ?) > 0
  `).get(q).count;

  const rows = db.prepare(`
    SELECT *
    FROM records
    WHERE instr(subject_code, ?) > 0
    ORDER BY updated_at DESC, id DESC
    LIMIT ? OFFSET ?
  `).all(q, pageSize, (page - 1) * pageSize);

  res.json({
    items: rows.map(publicRecord),
    total,
    page,
    pageSize
  });
});

// 查看单条记录，同时返回历史修改内容。
app.get("/api/records/:id", (req, res) => {
  const id = parseId(req.params.id);
  const record = getRecord(id);

  const audits = db.prepare(`
    SELECT *
    FROM audit_logs
    WHERE record_id = ?
    ORDER BY id DESC
  `).all(id).map(row => ({
    id: row.id,
    action: row.action,
    actor: row.actor,
    reason: row.reason,
    before: row.before_json ? JSON.parse(row.before_json) : null,
    after: JSON.parse(row.after_json),
    createdAt: row.created_at
  }));

  res.json({ record, audits });
});

// 记录及审计日志在同一事务中保存。
const createRecord = db.transaction((data, actor) => {
  const timestamp = now();

  const result = db.prepare(`
    INSERT INTO records (
      subject_code, visit_code, visit_date,
      pain_nrs, qmax, pvr, notes,
      version, created_by, created_at,
      updated_by, updated_at
    ) VALUES (
      @subjectCode, @visitCode, @visitDate,
      @painNrs, @qmax, @pvr, @notes,
      1, @actor, @timestamp, @actor, @timestamp
    )
  `).run({ ...data, actor, timestamp });

  const record = getRecord(Number(result.lastInsertRowid));

  writeAudit(record.id, "CREATE", actor, "首次录入", null, record);

  return record;
});

app.post("/api/records", (req, res) => {
  const data = validateRecord(req.body);
  const record = createRecord(data, req.actor);
  res.status(201).json(record);
});

const updateRecord = db.transaction(
  (id, data, version, reason, actor) => {
    const before = getRecord(id);

    // 身份字段不允许通过普通修改改变。
    if (
      data.subjectCode !== before.subjectCode ||
      data.visitCode !== before.visitCode
    ) {
      fail(400, "受试者编号和访视类型创建后不可修改");
    }

    if (before.version !== version) {
      fail(409, "记录已被修改，请返回列表并重新打开后核对");
    }

    const result = db.prepare(`
      UPDATE records SET
        visit_date = @visitDate,
        pain_nrs = @painNrs,
        qmax = @qmax,
        pvr = @pvr,
        notes = @notes,
        version = version + 1,
        updated_by = @actor,
        updated_at = @timestamp
      WHERE id = @id AND version = @version
    `).run({
      ...data,
      actor,
      timestamp: now(),
      id,
      version
    });

    if (result.changes !== 1) {
      fail(409, "版本冲突，请重新打开记录");
    }

    const after = getRecord(id);

    writeAudit(id, "UPDATE", actor, reason, before, after);

    return after;
  }
);

app.put("/api/records/:id", (req, res) => {
  const id = parseId(req.params.id);
  const data = validateRecord(req.body);
  const version = req.body.version;
  const reason = requiredText(req.body.reason, "修改原因", 300);

  if (!Number.isSafeInteger(version) || version < 1) {
    fail(400, "版本号无效");
  }

  const record = updateRecord(
    id, data, version, reason, req.actor
  );

  res.json(record);
});

app.use((req, res) => {
  res.status(404).json({ message: "接口不存在" });
});

app.use((error, req, res, next) => {
  if (error.code === "SQLITE_CONSTRAINT_UNIQUE") {
    return res.status(409).json({
      message: "该受试者的该次访视已存在，请打开原记录"
    });
  }

  const status = error.status || 500;

  // 不把数据库细节或患者记录输出到控制台。
  if (status >= 500) {
    console.error("Server error:", error.code || error.name);
  }

  res.status(status).json({
    message: status >= 500 ? "服务器内部错误" : error.message
  });
});

const server = app.listen(PORT, HOST, () => {
  console.log(`EDC API: http://${HOST}:${PORT}`);
});

process.on("SIGINT", () => {
  server.close(() => {
    db.close();
    process.exit(0);
  });
});
```

此版本没有提供删除记录的接口。错误记录的作废流程可在后续增加，避免直接删除后丢失历史。

---

**三、小程序公共文件**

**1. `miniprogram/project.config.json`**

```json
{
  "description": "本地 EDC 微信小程序",
  "projectname": "local-edc",
  "miniprogramRoot": "./",
  "compileType": "miniprogram",
  "appid": "touristappid",
  "setting": {
    "urlCheck": false,
    "es6": true,
    "postcss": true,
    "minified": true
  }
}
```

`touristappid` 用于工具支持的本地测试模式。真机预览时，请在开发者工具里改成你自己的小程序 AppID。

**2. `miniprogram/app.js`**

```javascript
App({
  globalData: {
    // 开发者工具模拟器访问本机后端。
    baseUrl: "http://127.0.0.1:3000/api"
  }
});
```

**3. `miniprogram/app.json`**

```json
{
  "pages": [
    "pages/login/login",
    "pages/records/records",
    "pages/record/record"
  ],
  "window": {
    "navigationBarTitleText": "研究 EDC",
    "navigationBarBackgroundColor": "#155e75",
    "navigationBarTextStyle": "white",
    "backgroundColor": "#f3f6fa"
  },
  "networkTimeout": {
    "request": 15000
  },
  "style": "v2"
}
```

**4. `miniprogram/app.wxss`**

```css
page {
  background: #f3f6fa;
  color: #172b4d;
  font-size: 28rpx;
}

.container {
  padding: 32rpx;
}

.title {
  font-size: 42rpx;
  font-weight: bold;
  margin-bottom: 16rpx;
}

.subtitle,
.muted {
  color: #64748b;
  font-size: 25rpx;
  line-height: 1.7;
}

.card {
  background: #ffffff;
  border-radius: 20rpx;
  padding: 28rpx;
  margin-bottom: 24rpx;
  box-shadow: 0 6rpx 24rpx rgba(15, 23, 42, 0.04);
}

.label {
  display: block;
  font-weight: bold;
  margin: 24rpx 0 12rpx;
}

input,
textarea,
.select {
  box-sizing: border-box;
  width: 100%;
  background: #f8fafc;
  border: 1rpx solid #dbe3ec;
  border-radius: 12rpx;
  padding: 18rpx;
  font-size: 28rpx;
}

input {
  height: 88rpx;
}

textarea {
  height: 180rpx;
}

button {
  margin-top: 22rpx;
  border-radius: 12rpx;
  font-size: 28rpx;
}

button.primary {
  color: white;
  background: #155e75;
}

button.secondary {
  color: #155e75;
  background: #e6f2f5;
}

.row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 20rpx;
}

.row input {
  flex: 1;
  width: 0;
}

.row button {
  margin: 0;
  flex-shrink: 0;
}

.record-title {
  font-size: 32rpx;
  font-weight: bold;
}

.badge {
  color: #155e75;
  background: #e6f2f5;
  border-radius: 8rpx;
  padding: 6rpx 12rpx;
  font-size: 23rpx;
}

.spacer {
  height: 24rpx;
}

.empty {
  text-align: center;
  padding: 70rpx 20rpx;
  color: #64748b;
}

.audit {
  border-top: 1rpx solid #e2e8f0;
  padding-top: 20rpx;
  margin-top: 20rpx;
}

.audit-text {
  display: block;
  font-size: 23rpx;
  white-space: pre-wrap;
  word-break: break-all;
  color: #475569;
}

.error {
  color: #b91c1c;
  padding: 20rpx 0;
}
```

**5. `miniprogram/utils/request.js`**

```javascript
function request(path, method = "GET", data = {}) {
  const token = wx.getStorageSync("edc_token");

  return new Promise((resolve, reject) => {
    wx.request({
      url: getApp().globalData.baseUrl + path,
      method,
      data,
      header: {
        "content-type": "application/json",
        Authorization: token ? `Bearer ${token}` : ""
      },

      success(res) {
        if (res.statusCode >= 200 && res.statusCode < 300) {
          resolve(res.data);
          return;
        }

        const error = new Error(
          (res.data && res.data.message) || "请求失败"
        );

        error.status = res.statusCode;

        if (res.statusCode === 401 && path !== "/login") {
          wx.removeStorageSync("edc_token");
          wx.removeStorageSync("edc_username");

          const pages = getCurrentPages();
          const current = pages[pages.length - 1];

          if (!current || current.route !== "pages/login/login") {
            wx.reLaunch({ url: "/pages/login/login" });
          }
        }

        reject(error);
      },

      fail() {
        reject(new Error("无法连接后端，请检查服务和网络地址"));
      }
    });
  });
}

module.exports = { request };
```

---

**四、登录页**

**1. `miniprogram/pages/login/login.wxml`**

```xml
<view class="container">
  <view class="spacer"></view>
  <view class="title">研究数据采集</view>
  <view class="subtitle">EDC 本地开发版 · 研究人员登录</view>

  <view class="spacer"></view>

  <view class="card">
    <view class="label">账号</view>
    <input
      value="{{username}}"
      data-field="username"
      bindinput="onInput"
      placeholder="请输入研究人员账号"
      maxlength="50"
    />

    <view class="label">密码</view>
    <input
      password="{{true}}"
      value="{{password}}"
      data-field="password"
      bindinput="onInput"
      placeholder="请输入密码"
      maxlength="256"
    />

    <button
      class="primary"
      loading="{{loading}}"
      disabled="{{loading}}"
      bindtap="login"
    >
      登录
    </button>
  </view>

  <view class="muted">
    使用后端 .env 中配置的账号密码。开发测试请使用模拟数据。
  </view>
</view>
```

**2. `miniprogram/pages/login/login.js`**

```javascript
const { request } = require("../../utils/request");

Page({
  data: {
    username: "",
    password: "",
    loading: false
  },

  onLoad() {
    if (wx.getStorageSync("edc_token")) {
      wx.reLaunch({ url: "/pages/records/records" });
    }
  },

  onInput(event) {
    const field = event.currentTarget.dataset.field;
    this.setData({ [field]: event.detail.value });
  },

  async login() {
    if (this.data.loading) return;

    const username = this.data.username.trim();
    const password = this.data.password;

    if (!username || !password) {
      wx.showToast({
        title: "请填写账号和密码",
        icon: "none"
      });
      return;
    }

    this.setData({ loading: true });

    try {
      const result = await request("/login", "POST", {
        username,
        password
      });

      wx.setStorageSync("edc_token", result.token);
      wx.setStorageSync("edc_username", result.username);

      this.setData({ password: "" });

      wx.reLaunch({ url: "/pages/records/records" });
    } catch (error) {
      wx.showToast({
        title: error.message,
        icon: "none",
        duration: 3000
      });
    } finally {
      this.setData({ loading: false });
    }
  }
});
```

---

**五、访视记录列表页**

**1. `miniprogram/pages/records/records.wxml`**

```xml
<view class="container">
  <view class="row">
    <view>
      <view class="title">访视记录</view>
      <view class="muted">当前账号：{{username}}</view>
    </view>
    <button size="mini" bindtap="logout">退出</button>
  </view>

  <view class="spacer"></view>

  <view class="card">
    <view class="row">
      <input
        value="{{query}}"
        bindinput="onSearchInput"
        placeholder="搜索受试者编号"
        maxlength="30"
        confirm-type="search"
        bindconfirm="search"
      />
      <button
        size="mini"
        disabled="{{loading}}"
        bindtap="search"
      >
        搜索
      </button>
    </view>

    <button class="primary" bindtap="createRecord">
      ＋ 新增访视记录
    </button>
  </view>

  <view class="muted">共 {{total}} 条记录</view>
  <view class="spacer"></view>

  <view
    wx:for="{{items}}"
    wx:key="id"
    class="card"
    data-id="{{item.id}}"
    bindtap="openRecord"
  >
    <view class="row">
      <view class="record-title">{{item.subjectCode}}</view>
      <view class="badge">{{item.visitLabel}}</view>
    </view>

    <view class="spacer"></view>
    <view>访视日期：{{item.visitDate}}</view>
    <view>疼痛 NRS：{{item.painNrs}}</view>
    <view class="muted">版本：{{item.version}} · 点击查看或修改</view>
  </view>

  <view wx:if="{{!loading && items.length === 0}}" class="empty">
    暂无记录
  </view>

  <button
    wx:if="{{items.length < total}}"
    loading="{{loading}}"
    disabled="{{loading}}"
    bindtap="loadMore"
  >
    加载更多
  </button>

  <view wx:if="{{loading}}" class="muted">正在加载……</view>
</view>
```

**2. `miniprogram/pages/records/records.js`**

```javascript
const { request } = require("../../utils/request");

const visitLabels = {
  BASELINE: "基线",
  W4: "第4周",
  W8: "第8周"
};

Page({
  data: {
    username: "",
    query: "",
    items: [],
    total: 0,
    page: 0,
    loading: false
  },

  onShow() {
    if (!wx.getStorageSync("edc_token")) {
      wx.reLaunch({ url: "/pages/login/login" });
      return;
    }

    this.setData({
      username: wx.getStorageSync("edc_username")
    });

    this.fetchRecords(true);
  },

  onSearchInput(event) {
    this.setData({ query: event.detail.value });
  },

  search() {
    this.fetchRecords(true);
  },

  async fetchRecords(reset) {
    if (this.data.loading) return;

    const page = reset ? 1 : this.data.page + 1;

    if (reset) {
      this.activeQuery = this.data.query.trim();
    }

    this.setData({ loading: true });

    try {
      const q = encodeURIComponent(this.activeQuery || "");

      const result = await request(
        `/records?q=${q}&page=${page}`
      );

      const items = result.items.map(item => ({
        ...item,
        visitLabel: visitLabels[item.visitCode] || item.visitCode
      }));

      this.setData({
        items: reset ? items : this.data.items.concat(items),
        total: result.total,
        page: result.page
      });
    } catch (error) {
      wx.showToast({
        title: error.message,
        icon: "none",
        duration: 3000
      });
    } finally {
      this.setData({ loading: false });
    }
  },

  loadMore() {
    this.fetchRecords(false);
  },

  createRecord() {
    wx.navigateTo({ url: "/pages/record/record" });
  },

  openRecord(event) {
    const id = event.currentTarget.dataset.id;

    wx.navigateTo({
      url: `/pages/record/record?id=${id}`
    });
  },

  async logout() {
    try {
      await request("/logout", "POST");
    } catch (error) {
      // 网络断开时仍允许清除本机登录状态。
    }

    wx.removeStorageSync("edc_token");
    wx.removeStorageSync("edc_username");

    wx.reLaunch({ url: "/pages/login/login" });
  }
});
```

---

**六、新增、编辑及审计记录页**

**1. `miniprogram/pages/record/record.wxml`**

```xml
<view class="container">
  <view class="title">
    {{id ? '查看 / 修改访视' : '新增访视'}}
  </view>

  <view class="muted">
    仅填写受试者研究编号。不要在备注中输入姓名、身份证号或电话。
  </view>

  <view wx:if="{{loading}}" class="card">正在加载……</view>
  <view wx:if="{{loadError}}" class="error">{{loadError}}</view>

  <block wx:if="{{ready}}">
    <view class="card">
      <view class="label">受试者编号 *</view>
      <input
        value="{{form.subjectCode}}"
        disabled="{{id > 0}}"
        data-field="subjectCode"
        bindinput="onInput"
        placeholder="例如 S001"
        maxlength="30"
      />

      <view class="label">访视类型 *</view>
      <picker
        range="{{visitLabels}}"
        value="{{visitIndex}}"
        disabled="{{id > 0}}"
        bindchange="onVisitChange"
      >
        <view class="select">{{visitLabels[visitIndex]}}</view>
      </picker>

      <view class="label">访视日期 *</view>
      <picker
        mode="date"
        value="{{form.visitDate}}"
        bindchange="onDateChange"
      >
        <view class="select">{{form.visitDate}}</view>
      </picker>

      <view class="label">膀胱疼痛 NRS：0～10 *</view>
      <input
        type="number"
        value="{{form.painNrs}}"
        data-field="painNrs"
        bindinput="onInput"
        placeholder="请输入 0～10 的整数"
      />

      <view class="label">最大尿流率 Qmax（mL/s）</view>
      <input
        type="digit"
        value="{{form.qmax}}"
        data-field="qmax"
        bindinput="onInput"
        placeholder="未测量请留空"
      />

      <view class="label">排尿后残余尿 PVR（mL）</view>
      <input
        type="digit"
        value="{{form.pvr}}"
        data-field="pvr"
        bindinput="onInput"
        placeholder="未测量请留空"
      />

      <view class="label">备注</view>
      <textarea
        value="{{form.notes}}"
        data-field="notes"
        bindinput="onInput"
        maxlength="1000"
        placeholder="例如：检查条件、数据缺失原因"
      />

      <block wx:if="{{id}}">
        <view class="label">本次修改原因 *</view>
        <textarea
          value="{{reason}}"
          bindinput="onReasonInput"
          maxlength="300"
          placeholder="例如：根据原始检查报告更正录入数值"
        />

        <view class="muted">当前版本：{{version}}</view>
      </block>

      <button
        class="primary"
        loading="{{saving}}"
        disabled="{{saving}}"
        bindtap="save"
      >
        {{id ? '保存修改' : '保存记录'}}
      </button>
    </view>

    <view wx:if="{{id}}" class="card">
      <view class="record-title">修改历史</view>

      <view
        wx:for="{{audits}}"
        wx:key="id"
        class="audit"
      >
        <view>{{item.actionLabel}} · {{item.actor}}</view>
        <view class="muted">{{item.timeLabel}}</view>
        <view>原因：{{item.reason}}</view>

        <view class="label">变更前</view>
        <text selectable="{{true}}" class="audit-text">
          {{item.beforeText}}
        </text>

        <view class="label">变更后</view>
        <text selectable="{{true}}" class="audit-text">
          {{item.afterText}}
        </text>
      </view>
    </view>
  </block>
</view>
```

**2. `miniprogram/pages/record/record.js`**

```javascript
const { request } = require("../../utils/request");

const visitCodes = ["BASELINE", "W4", "W8"];
const visitLabels = ["基线", "第4周", "第8周"];

function today() {
  const date = new Date();
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");

  return `${year}-${month}-${day}`;
}

function displayValue(value) {
  return value === null || value === undefined
    ? ""
    : String(value);
}

function auditText(record) {
  if (!record) return "无";

  return [
    `受试者：${record.subjectCode}`,
    `访视：${record.visitCode}`,
    `日期：${record.visitDate}`,
    `疼痛 NRS：${record.painNrs}`,
    `Qmax：${record.qmax === null ? "未填写" : record.qmax}`,
    `PVR：${record.pvr === null ? "未填写" : record.pvr}`,
    `备注：${record.notes || "无"}`,
    `版本：${record.version}`
  ].join("\n");
}

Page({
  data: {
    id: 0,
    version: 0,
    visitIndex: 0,
    visitLabels,
    form: {
      subjectCode: "",
      visitCode: "BASELINE",
      visitDate: "",
      painNrs: "",
      qmax: "",
      pvr: "",
      notes: ""
    },
    reason: "",
    audits: [],
    loading: false,
    saving: false,
    ready: false,
    loadError: ""
  },

  onLoad(options) {
    if (!wx.getStorageSync("edc_token")) {
      wx.reLaunch({ url: "/pages/login/login" });
      return;
    }

    this.setData({ "form.visitDate": today() });

    if (options.id) {
      const id = Number(options.id);

      if (!Number.isSafeInteger(id) || id <= 0) {
        this.setData({ loadError: "记录 ID 无效" });
        return;
      }

      this.setData({ id });
      this.loadRecord();
    } else {
      this.setData({ ready: true });
    }
  },

  async loadRecord() {
    this.setData({
      loading: true,
      ready: false,
      loadError: ""
    });

    try {
      const result = await request(`/records/${this.data.id}`);
      const record = result.record;

      this.setData({
        version: record.version,
        visitIndex: visitCodes.indexOf(record.visitCode),

        form: {
          subjectCode: record.subjectCode,
          visitCode: record.visitCode,
          visitDate: record.visitDate,
          painNrs: displayValue(record.painNrs),
          qmax: displayValue(record.qmax),
          pvr: displayValue(record.pvr),
          notes: record.notes
        },

        audits: result.audits.map(item => ({
          ...item,
          actionLabel: item.action === "CREATE" ? "创建" : "修改",
          timeLabel: item.createdAt.replace("T", " ").replace("Z", " UTC"),
          beforeText: auditText(item.before),
          afterText: auditText(item.after)
        })),

        ready: true
      });
    } catch (error) {
      this.setData({ loadError: error.message });
    } finally {
      this.setData({ loading: false });
    }
  },

  onInput(event) {
    const field = event.currentTarget.dataset.field;

    this.setData({
      [`form.${field}`]: event.detail.value
    });
  },

  onVisitChange(event) {
    const index = Number(event.detail.value);

    this.setData({
      visitIndex: index,
      "form.visitCode": visitCodes[index]
    });
  },

  onDateChange(event) {
    this.setData({
      "form.visitDate": event.detail.value
    });
  },

  onReasonInput(event) {
    this.setData({ reason: event.detail.value });
  },

  validate() {
    const form = this.data.form;

    if (!/^[A-Za-z0-9-]{1,30}$/.test(form.subjectCode.trim())) {
      return "受试者编号应为字母、数字或短横线";
    }

    if (!form.visitDate) return "请选择访视日期";

    const pain = Number(form.painNrs);

    if (
      String(form.painNrs).trim() === "" ||
      !Number.isInteger(pain) ||
      pain < 0 ||
      pain > 10
    ) {
      return "疼痛 NRS 应为 0～10 的整数";
    }

    for (const field of ["qmax", "pvr"]) {
      const value = String(form[field]).trim();

      if (
        value !== "" &&
        (!Number.isFinite(Number(value)) || Number(value) < 0)
      ) {
        return `${field.toUpperCase()} 应为非负数字`;
      }
    }

    if (this.data.id && !this.data.reason.trim()) {
      return "请填写修改原因";
    }

    return "";
  },

  async save() {
    if (this.data.saving || !this.data.ready) return;

    const message = this.validate();

    if (message) {
      wx.showToast({
        title: message,
        icon: "none",
        duration: 3000
      });
      return;
    }

    this.setData({ saving: true });

    const form = this.data.form;

    const payload = {
      ...form,
      subjectCode: form.subjectCode.trim().toUpperCase(),
      painNrs: Number(form.painNrs),
      qmax: String(form.qmax).trim() === "" ? null : Number(form.qmax),
      pvr: String(form.pvr).trim() === "" ? null : Number(form.pvr)
    };

    try {
      if (this.data.id) {
        await request(`/records/${this.data.id}`, "PUT", {
          ...payload,
          version: this.data.version,
          reason: this.data.reason.trim()
        });
      } else {
        await request("/records", "POST", payload);
      }

      // 保存后回到列表，防止在旧页面再次提交。
      wx.redirectTo({
        url: "/pages/records/records",
        success() {
          wx.showToast({ title: "保存成功", icon: "success" });
        }
      });
    } catch (error) {
      wx.showModal({
        title: error.status === 409 ? "请核对记录" : "保存失败",
        content: error.message,
        showCancel: false
      });
    } finally {
      this.setData({ saving: false });
    }
  }
});
```

注意：代码把**未填写的 Qmax、PVR 保存为 `null`**，不会错误地当成 `0`。

---

**七、怎么运行**

**第 1 步：准备软件**

安装：

- [Node.js](https://nodejs.org/)：选择 24.x。
- [微信开发者工具](https://developers.weixin.qq.com/miniprogram/dev/devtools/download.html)。

本地创建 `edc-project` 文件夹，按前面的目录结构保存代码。

**第 2 步：启动后端**

以下以 Windows PowerShell 为例。

进入后端目录：

```powershell
cd C:\你的路径\edc-project\server
```

复制环境配置：

```powershell
Copy-Item .env.example .env
```

用记事本打开：

```powershell
notepad .env
```

把密码改成你自己的至少 12 位密码，然后保存。

安装依赖：

```powershell
npm install
```

启动：

```powershell
npm start
```

看到：

```text
EDC API: http://127.0.0.1:3000
```

说明服务已经启动。**这个终端窗口先不要关闭。**

浏览器访问：

```text
http://127.0.0.1:3000/api/health
```

应该返回：

```json
{
  "ok": true
}
```

若 better-sqlite3 安装失败，先确认 Node.js 版本；Windows 上必要时安装 Node.js 安装器提供的原生模块构建工具。[GitHub](https://github.com/WiseLibs/better-sqlite3/blob/master/docs/troubleshooting.md?utm_source=chatgpt.com)

**第 3 步：导入微信小程序**

在微信开发者工具中：

1. 选择“导入项目”。
2. 项目目录选 `edc-project/miniprogram`。
3. 使用你的小程序 AppID；本地模拟测试也可使用工具提供的测试模式。
4. 后端服务选择“不使用云服务”。
5. 在“详情 → 本地设置”中，启用开发环境的“不校验合法域名、TLS 版本及 HTTPS 证书”。
6. 点击“编译”。

不同工具版本的选项名称可能略有差异。网络规则可参考[微信小程序网络说明](https://developers.weixin.qq.com/miniprogram/dev/framework/ability/network.html)。

**第 4 步：登录并测试**

输入 `.env` 中配置的账号和密码。

按下面顺序检查：

| 操作 | 预期结果 |
|---|---|
| 新增 `S001`、基线访视 | 保存成功，列表出现记录 |
| 再新增 `S001`、基线访视 | 提示该访视已存在 |
| NRS 输入 `11` | 不允许保存 |
| Qmax、PVR 留空 | 作为缺失值保存 |
| 修改记录但不填原因 | 不允许保存 |
| 填写原因后修改 | 版本增加，修改历史出现前后内容 |
| 关闭并重启后端 | 数据保留，需要重新登录 |

以上是运行验收步骤；**我没有在你的本机或微信开发者工具中实际执行这些代码。**

---

**八、手机真机调试怎么连接**

开发者工具模拟器可以使用：

```text
http://127.0.0.1:3000/api
```

但手机上的 `127.0.0.1` 指的是手机自己，因此真机访问需要修改地址。

1. 让电脑和手机连接同一个局域网。
2. 在电脑运行：

```powershell
ipconfig
```

找到电脑的 IPv4 地址，例如：

```text
192.168.1.20
```

3. 把后端 `.env` 改成：

```dotenv
HOST=0.0.0.0
PORT=3000

EDC_USERNAME=researcher
EDC_PASSWORD=你已经设置的密码
```

4. 重启后端，把 `miniprogram/app.js` 改成：

```javascript
App({
  globalData: {
    baseUrl: "http://192.168.1.20:3000/api"
  }
});
```

5. Windows 防火墙如拦截连接，仅对可信的专用网络放行 Node.js 或 TCP 3000 端口。
6. 使用自己的 AppID，在开发者工具中进行真机调试；根据调试模式启用相应的域名校验跳过选项。

**这属于局域网开发调试方案，HTTP 下只使用模拟数据。**正式发布小程序需要按微信要求配置服务域名和 HTTPS；后端可以部署在自有服务器上，不必使用云开发或 GitHub。

---

**九、数据保存在哪里，以及当前边界**

数据库在：

```text
edc-project/server/data/edc.sqlite
```

备份时，先停止 Node.js 后端，再复制整个 `data` 文件夹。运行期间不要只复制主数据库文件，因为 SQLite 的 WAL 文件可能包含尚未合并的数据。
