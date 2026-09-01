---
tags: [类型/概念, 技术/HTTP]
aliases: [超文本传输协议, Hypertext Transfer Protocol]
created: 2026-09-01
updated: 2026-09-01
---
> HTTP 是浏览器和服务器之间的对话格式：客户端发一段纯文本说「我要什么」，服务器回一段纯文本说「给你什么」，两段文本的排版规则都是死的——请求行/状态行、若干请求头、一个空行、然后是正文。

## 典型场景

前端同学甩来一句「你这个接口调不通」。你打开浏览器按 F12，切到 Network 面板，点开那条飘红的请求，看见 General、Request Headers、Response Headers、Payload 一堆折叠区块，每个区块里全是 `Content-Type`、`405`、`Host` 这样的词。

这个面板不是浏览器发明的展示格式，它只是把**真实发出去的那几百个字节**拆开摆给你看。看懂它，等价于看懂 HTTP 报文的排版规则。而这套规则一共只有四行结构。

## HTTP 是什么

HTTP（HyperText Transfer Protocol，超文本传输协议）是一个**应用层协议**——所谓应用层，指的是它只管「这段话怎么写」，不管「这段话怎么送到对面」。送的活儿交给下层的 TCP：先握手建立一条可靠的字节流通道，HTTP 再把自己的文本报文往里灌。

它有三个性质决定了后面所有的设计：

**请求-响应模型。** 必须客户端先开口，服务器才能回话，而且一问一答严格配对。服务器不能主动给浏览器推消息（这正是后来要发明 WebSocket 的原因）。

**基于文本。** 报文的头部是人能直接读的 ASCII 文本，不是二进制结构体。代价是啰嗦、占带宽，回报是好调试——你用 `curl -v` 就能把它整个打印出来看。

**无状态。** 服务器处理完一个请求就把这次交互忘干净了，下一个请求过来时它不记得你是谁。所以「登录状态」这种东西 HTTP 本身不提供，得靠每次请求都自带一张身份凭证（Cookie）来打补丁。

默认端口：HTTP 走 80，HTTPS 走 443。所以 `http://example.com/` 和 `http://example.com:80/` 是同一个地址。

## 手把手：看一次真实的请求

`curl` 加上 `-v`（verbose）会把原始报文打出来，`>` 开头的行是发出去的，`<` 开头的是收回来的：

```bash
curl -v http://example.com
```

实际输出（省略了连接细节和正文）：

```http
> GET / HTTP/1.1
> Host: example.com
> User-Agent: curl/8.7.1
> Accept: */*
>
< HTTP/1.1 200 OK
< Date: Tue, 01 Sep 2026 08:34:38 GMT
< Content-Type: text/html
< Transfer-Encoding: chunked
< Connection: keep-alive
< Server: cloudflare
< Last-Modified: Mon, 31 Aug 2026 04:09:32 GMT
< Allow: GET, HEAD
```

注意发出去的部分最后有一个**光秃秃的 `>`**，那就是**空行**。它不是排版留白，是协议规定的分隔符：空行以上是头部，空行以下是正文。服务器读到空行就知道「头读完了」。

这里的请求没有正文，所以空行之后直接结束了。

## 请求报文的四段结构

```text
请求行      POST /login HTTP/1.1
请求头      Host: example.com
请求头      Content-Type: application/x-www-form-urlencoded
请求头      Content-Length: 30
空行
请求体      username=jory&password=hunter2
```

### 请求行

一行三段，用空格隔开：

```http
POST /login HTTP/1.1
```

| 位置 | 叫法 | 含义 |
| --- | --- | --- |
| `POST` | 请求方法 | 你想对资源做什么 |
| `/login` | 请求路径 | 对哪个资源做 |
| `HTTP/1.1` | 协议版本 | 按哪版规则说话 |

### 请求方法

方法表达的是**意图**。服务器完全有权拒绝一个它不支持的方法：

| 方法 | 干什么 | 安全 | 幂等 |
| --- | --- | --- | --- |
| `GET` | 取一份资源的表示，不应该改动服务器数据 | ✅ | ✅ |
| `HEAD` | 和 `GET` 一样但只要响应头、不要正文 | ✅ | ✅ |
| `POST` | 提交数据给资源处理，通常导致状态变化 | ❌ | ❌ |
| `PUT` | 用请求体整个替换目标资源 | ❌ | ✅ |
| `DELETE` | 删除资源 | ❌ | ✅ |
| `PATCH` | 局部修改资源 | ❌ | ❌ |
| `OPTIONS` | 询问这个资源支持哪些通信选项 | ✅ | ✅ |
| `TRACE` | 回显收到的请求，用来做链路诊断 | ✅ | ✅ |
| `CONNECT` | 建立到目标的隧道，代理用 | ❌ | ❌ |

表里两个术语第一次出现，就地解释：

- **安全（safe）**：这个方法不打算改变服务器状态，只读。所以爬虫可以随便发 `GET`，但不该乱发 `POST`
- **幂等（idempotent）**：同样的请求发一次和发 N 次，服务器的最终状态一样。`DELETE` 删同一个 id 两次，第二次删不掉了，但「资源不存在」这个最终状态没变，所以它幂等；`POST` 提交订单两次会生成两个订单，所以不幂等

幂等不是学术洁癖，它直接决定**失败了能不能自动重试**。网络超时的时候你不知道请求到底送达了没有，`PUT` 可以闭眼重发，`POST` 重发就可能扣两次款。

### 请求头

每行一个 `名字: 值`，大小写不敏感。常见的几个：

| 请求头 | 作用 |
| --- | --- |
| `Host` | 目标主机名。**HTTP/1.1 里必须有**，因为一个 IP 上常常挂着几十个网站，服务器靠它区分你找谁 |
| `User-Agent` | 客户端自报家门，浏览器/curl/爬虫都在这里表明身份 |
| `Accept` | 我能接受哪些格式的响应，比如 `application/json` |
| `Content-Type` | **请求体**是什么格式，只在有请求体时才需要 |
| `Content-Length` | 请求体有多少字节 |
| `Cookie` | 把服务器之前发给我的凭证带回去，无状态的补丁 |
| `Connection` | 这条 TCP 连接用完是留着还是关掉 |

`Content-Type` 和 `Accept` 容易搞混：**`Content-Type` 描述我发给你的东西，`Accept` 描述我想收到的东西。**

### 请求体

`GET` 和 `DELETE` 通常没有请求体，`POST`、`PUT`、`PATCH` 有。请求体的格式由 `Content-Type` 声明，表单提交最常见的两种：

- `application/x-www-form-urlencoded` — 普通表单，编码成 `a=1&b=2` 这样的查询串
- `application/json` — 前后端分离项目里的主流

跑一个真实的 POST 看看：

```bash
curl -v -X POST http://example.com/login -d 'username=jory&password=hunter2'
```

发出去的部分：

```http
> POST /login HTTP/1.1
> Host: example.com
> User-Agent: curl/8.7.1
> Accept: */*
> Content-Length: 30
> Content-Type: application/x-www-form-urlencoded
>
```

`-d` 一加上，curl 自动做了三件事：方法变成 `POST`、补上 `Content-Type: application/x-www-form-urlencoded`、数出正文长度填进 `Content-Length`。这三件事本来都该由发请求的人负责。

## 响应报文的四段结构

结构和请求完全对称，只有第一行不同：

```http
HTTP/1.1 200 OK
Content-Type: text/html
Server: cloudflare

<!doctype html>...
```

### 状态行

```http
HTTP/1.1 200 OK
```

| 位置 | 叫法 | 含义 |
| --- | --- | --- |
| `HTTP/1.1` | 协议版本 | — |
| `200` | 状态码 | 机器读的结果码 |
| `OK` | 原因短语 | 给人看的说明，可以为空，程序不该依赖它 |

### 状态码

**首位数字定性质，后两位定细节。** 记住五个大类比背具体码值有用得多：

| 类别 | 名称 | 含义 |
| --- | --- | --- |
| `1xx` | Informational | 中间状态，请求收到了，继续 |
| `2xx` | Successful | 成功 |
| `3xx` | Redirection | 还得再跑一趟别的地址 |
| `4xx` | Client error | **你请求写错了**，改请求 |
| `5xx` | Server error | **服务器自己崩了**，改服务器 |

`4xx` 和 `5xx` 的分界是排错时最省时间的一条信息：`4xx` 说明请求根本没通过服务器的入口检查，去看 URL、方法、参数、认证；`5xx` 说明请求进去了、代码跑炸了，去看服务端日志。

常用的具体码：

| 码 | 原因短语 | 什么时候出现 |
| --- | --- | --- |
| `200` | OK | 成功，正文里是结果 |
| `201` | Created | 成功并且创建了新资源，常配 `POST` |
| `204` | No Content | 成功但没有正文，常配 `DELETE` |
| `301` | Moved Permanently | 永久搬家了，以后直接找新地址 |
| `302` | Found | 临时跳转，下次还来问我 |
| `304` | Not Modified | 你缓存里那份还能用，我不重发了 |
| `400` | Bad Request | 请求本身有毛病，服务器看不懂 |
| `401` | Unauthorized | 没认证，你得先证明你是谁 |
| `403` | Forbidden | 认证了但没权限 |
| `404` | Not Found | 找不到这个资源 |
| `405` | Method Not Allowed | 路径对，方法不对 |
| `500` | Internal Server Error | 服务端抛异常了 |
| `502` | Bad Gateway | 网关从上游拿到了无效响应 |
| `503` | Service Unavailable | 服务暂时不可用，维护或过载 |

**`401` 和 `403` 的区别值得记牢：`401` 是「你是谁」没解决，`403` 是「你是谁」解决了但「你不配」。** 前者重新登录有用，后者重新登录也没用。

上面那个 POST 的例子实际收到的就是：

```http
< HTTP/1.1 405 Method Not Allowed
```

因为 `example.com` 只是个示例站点，同一次 `GET` 的响应头里明明白白写着 `Allow: GET, HEAD`——它只认这两个方法。`405` 配 `Allow` 头是标准做法，服务器在告诉你「换个方法再来」。

### 响应头

| 响应头 | 作用 |
| --- | --- |
| `Content-Type` | 正文是什么格式，浏览器靠它决定渲染还是下载 |
| `Content-Length` | 正文字节数 |
| `Transfer-Encoding: chunked` | 正文分块传输，长度事先不知道，所以没有 `Content-Length` |
| `Location` | 配合 `3xx`，告诉客户端新地址在哪 |
| `Set-Cookie` | 给客户端种一张凭证，下次请求靠它认人 |
| `Server` | 服务器软件自报家门 |
| `Allow` | 配合 `405`，列出这个资源支持的方法 |

`Content-Length` 和 `Transfer-Encoding: chunked` 是**二选一**的关系，都在回答同一个问题：接收方怎么知道正文读到哪算完。前者事先报总长度，后者边生成边发、每块自带长度、最后发一个长度为 0 的块收尾。动态生成的页面常用后者，因为写第一个字节的时候还不知道总共会有多长。

## 连接是怎么复用的

HTTP/1.0 的模型是**一次请求一条 TCP 连接**：握手、发请求、收响应、关闭。一个网页引用几十个图片和脚本，就要重复几十次 TCP 三次握手，延迟全花在建连上了。

HTTP/1.1 把**持久连接改成了默认行为**：一条 TCP 连接上可以连续跑多个请求-响应，不用每次重建。想关掉就显式发 `Connection: close`。

前面那个真实响应里的 `Connection: keep-alive` 就是这件事的痕迹——虽然 HTTP/1.1 里已经不需要这个头了，服务器还是习惯带上，用来兼容那些可能退回 HTTP/1.0 的客户端。

HTTP/1.1 还允许**管线化**（pipelining）：不等上一个响应回来就接着发下一个请求。但响应必须按请求的顺序返回，前面一个慢的就把后面全堵住，这叫**队头阻塞**（head-of-line blocking）。因为这个毛病加上代理实现普遍有 bug，现代浏览器默认不开管线化，这个问题最终由 HTTP/2 的多路复用解决。

## 参考
- [RFC 9110: HTTP Semantics](https://www.rfc-editor.org/rfc/rfc9110.html) — 与版本无关的语义：方法、状态码、字段
- [RFC 9112: HTTP/1.1](https://www.rfc-editor.org/rfc/rfc9112.html) — HTTP/1.1 的报文语法与连接管理
- [MDN: HTTP messages](https://developer.mozilla.org/en-US/docs/Web/HTTP/Guides/Messages)
- [MDN: Connection management in HTTP/1.x](https://developer.mozilla.org/en-US/docs/Web/HTTP/Guides/Connection_management_in_HTTP_1.x)
