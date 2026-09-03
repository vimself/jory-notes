---
tags: [类型/概念, 技术/JavaScript, 技术/HTTP]
aliases: []
created: 2026-09-03
updated: 2026-09-03
---
> AJAX 不是一个新 API 的名字，是「让 JavaScript 自己发 HTTP 请求、拿到数据后只更新页面一小块」这套做法的统称。服务器那边毫无察觉——它收到的还是一个普通请求，区别全在浏览器怎么处理响应。

## 典型场景

注册页有个用户名输入框。你希望光标一离开它，页面上就冒出一行「该用户名已被占用」。

不用 AJAX 的话，这件事只能等到点「提交」之后：浏览器把整个表单发过去，服务器返回一张新页面，白屏闪一下，用户填的密码、手机号全没了，得重填。为了检查一个字段，整个页面被换掉了一次。

你真正想要的是：**悄悄问服务器一句，只把那行红字塞进页面，其他地方一动不动。**

## 同步提交和异步请求，差在哪

```text
表单提交（同步）
  点击 → 浏览器导航到新地址 → 白屏 → 整个 DOM 被响应替换
        用户在这段时间里什么也干不了

AJAX（异步）
  失焦 → JS 发请求 ─────────┐   页面照常可用，用户继续填别的
        （不阻塞）           │
        ┌───────────────────┘
        ↓ 响应回来了
        回调函数拿到数据 → JS 只改 #tip 这一个元素
```

关键在于：**服务器分不出这两者**。两边发过去的都是 [[HTTP]] 请求，报文结构一模一样。差别只有一处——普通请求的响应由浏览器拿去替换整个页面，AJAX 请求的响应交给你写的那个函数处理。

所以后端不需要为 AJAX 学新东西，只是响应体从一整页 HTML 变成了一小段 [[JSON]]。

## 原生写法：XMLHttpRequest

这是浏览器提供的原始工具，先看一遍，理解「异步」到底是怎么回事：

```javascript
const xhr = new XMLHttpRequest();

xhr.open("GET", "/app/user/check?userName=zhangsan");   // 还没发出去
xhr.onreadystatechange = function () {                  // 先把回调挂上
  if (xhr.readyState === 4 && xhr.status === 200) {
    document.querySelector("#tip").innerText = xhr.responseText;
  }
};
xhr.send();                                             // 现在才发，而且立刻返回
```

`send()` 调完立刻就返回了，响应还没到。等响应到达时，浏览器再回头调用你挂上去的那个函数——**这就是「异步」的全部含义：不是并行、不是多线程，是「等东西回来了再叫你」。**

`readyState` 表示请求走到了哪一步：

| 值 | 名字 | 含义 |
| --- | --- | --- |
| 0 | `UNSENT` | 对象建好了，还没调 `open()` |
| 1 | `OPENED` | `open()` 调过了，可以设请求头、可以 `send()` |
| 2 | `HEADERS_RECEIVED` | `send()` 调过了，响应头和状态码到了 |
| 3 | `LOADING` | 响应体正在下载，`responseText` 里是残缺的一半 |
| 4 | `DONE` | 结束了 |

**`readyState === 4` 只表示「结束了」，不表示「成功了」**——404 和 500 同样会走到 4。所以判断条件里必须再加一个 `status === 200`，这两个条件缺一不可。

`open()` 的第三个参数是 `async`，默认 `true`。传 `false` 会变成同步请求：`send()` 会一直卡住不返回，整个页面在等待期间彻底失去响应。MDN 的措辞很直接：主线程上的同步请求会严重破坏用户体验，应当避免，很多浏览器已经完全废弃了这种用法。**别用。**

## 用 Axios 把上面那段缩短

原生写法啰嗦在两处：回调里要自己判断状态，拿到的 `responseText` 是字符串还得自己解析。Axios 是一个把这些都包好的库，引一个 `<script>` 就能用：

```html
<script src="https://cdn.jsdelivr.net/npm/axios@1.13.2/dist/axios.min.js"></script>
```

（官方文档建议在生产环境里锁定版本号，别用不带版本的地址，免得哪天库升级把你的页面搞挂。）

同一件事，Axios 版本：

```javascript
axios.get("/app/user/check", { params: { userName: "zhangsan" } })
     .then(res => {
         document.querySelector("#tip").innerText = res.data.message;
     })
     .catch(err => {
         console.error(err);
     });
```

三个变化值得说清楚：

**一、`params` 会被拼成查询串。** 你不用自己拼 `?userName=zhangsan`，也不用操心转义。

**二、`res.data` 已经是解析好的 JavaScript 对象**，不是字符串。响应体是 JSON 时 Axios 自动帮你 `JSON.parse` 了，所以直接 `res.data.message` 就能取值。要注意 `res` 本身不是数据，它是整个响应——`res.data` 是响应体，`res.status` 是状态码。

**三、失败走 `catch`。** 服务器返回 2xx 之外的状态码时，这个 Promise 会被拒绝，`err.response` 里装着响应（`err.response.status`、`err.response.data`）；如果压根没收到响应（比如网络断了），那就只有 `err.request`。

发 POST 时更能看出差距：

```javascript
axios.post("/app/user/register", { userName: "张三", age: 18 })
     .then(res => { /* ... */ });
```

第二个参数直接给对象，Axios 会**自动把它序列化成 JSON 字符串，并把请求头设成 `Content-Type: application/json`**。

这一点对后端有直接影响：请求体不再是表单格式，[[Servlet]] 里的 `getParameter` 就取不到值了，得从 `getReader()` 里把 JSON 原文读出来再解析。这不是 bug，是两种不同的请求体格式，细节见 [[JSON]]。

还有一个写法是把配置整个传进去，和 `axios.get`/`axios.post` 等价：

```javascript
axios({
    method: "post",
    url: "/app/user/register",
    data: { userName: "张三", age: 18 }
}).then(res => { /* ... */ });
```

## 浏览器自带的 fetch

现代浏览器还内置了 `fetch()`，不用引任何库：

```javascript
fetch("/app/user/check?userName=zhangsan")
    .then(response => response.json())     // 解析 JSON 是单独一步
    .then(data => { /* ... */ });
```

它和 Axios 有一个必须知道的区别：**`fetch()` 返回的 Promise 只在请求本身失败时才拒绝**（网址不合法、网络断了）。服务器返回 404 或 504 时它照样 resolve，`catch` 不会执行。MDN 的说法是，你得自己在 `then` 里检查 `response.ok` 或 `response.status`。

习惯了 Axios 那套「非 2xx 就 catch」的人，第一次用 fetch 常常写出「明明 500 了，前端还当成功处理」的代码。

## 三个坑

**一、异步不是并行，回调外面读不到回调里的东西。**

```javascript
let result;
axios.get("/api/x").then(res => { result = res.data; });
console.log(result);          // undefined —— 这行比 then 里的代码先执行
```

请求还在路上时，`console.log` 就已经跑完了。要用数据，就把用它的代码写进 `then` 里（或者用 `async/await` 把它拉平）。

**二、状态码不等于业务结果。** HTTP 200 只说明「请求送达并被处理了」。「用户名已占用」是一个正常的业务结论，服务端通常还是返回 200，把结论放在响应体里。别把业务失败做成 500——那会让前端的错误处理和真正的服务器故障混成一团。

**三、跨域会被浏览器拦下。** 页面地址和请求地址只要协议、域名、端口有一处不同，就属于跨域，浏览器默认不让你读响应。这是浏览器的安全策略（[[同源策略]]），不是服务器拒绝了你——服务端得显式表示允许才行。本地开发时前后端分端口跑，撞上它的概率很高。

## 参考

- [MDN: XMLHttpRequest.readyState](https://developer.mozilla.org/en-US/docs/Web/API/XMLHttpRequest/readyState) — 五个状态值的含义
- [MDN: XMLHttpRequest.open()](https://developer.mozilla.org/en-US/docs/Web/API/XMLHttpRequest/open) — `async` 参数与同步请求的警告
- [MDN: fetch()](https://developer.mozilla.org/en-US/docs/Web/API/Window/fetch) — Promise 什么时候才会被拒绝
- [Axios 文档](https://axios-http.com/docs/intro) — 请求配置项、响应结构与错误处理
