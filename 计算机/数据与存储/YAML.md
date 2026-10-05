---
tags: [类型/概念, 技术/YAML]
aliases: [YML]
created: 2026-10-05
updated: 2026-10-05
---
> YAML 是一种写配置用的文本格式：缩进表示层级，`key: value` 表示键值对，`- ` 开头表示列表项，写同样的配置比 properties 和 [[JSON]] 都短。代价是两条：缩进错一格，结构就变了；不加引号的值会被解析器按规则猜成别的类型，`yes` 可能读成布尔值，`0123` 可能读成八进制数 83。

## 典型场景

一个 Web 项目的数据库和服务器配置，用 properties 写是这样：

```properties
server.port=8080
server.servlet.context-path=/api
spring.datasource.url=jdbc:mysql://localhost:3306/ssm_db
spring.datasource.username=root
spring.datasource.password=root
```

`spring.datasource.` 重复了三遍。配置一多，前缀重复几十遍，想看「数据源一共配了哪些项」得自己用眼睛分组。

同样的内容写成 YAML：

```yaml
server:
  port: 8080
  servlet:
    context-path: /api
spring:
  datasource:
    url: jdbc:mysql://localhost:3306/ssm_db
    username: root
    password: root
```

公共前缀只写一次，同一组的配置自然排在一起。[[Spring Boot]] 的 `application.yml`、GitHub Actions 的工作流文件、Docker Compose 文件用的都是这种格式。

写法上省事，但有几个坑：上面这份如果把 `password` 改成 `0123`，有的解析器读出来的是整数 83。

## 三种基本结构

YAML 里所有数据都由三种结构搭起来：**映射**（mapping，键值对的集合，相当于 Java 的 `Map`、JSON 的对象）、**序列**（sequence，有序列表，相当于 `List`、JSON 的数组）、**标量**（scalar，单个值：字符串、数字、布尔值、空值）。

### 映射：键值对

```yaml
host: localhost
port: 8080
```

**冒号后面必须有空格。** 少了空格，`port:8080` 不是键值对，而是一个字符串。用 PyYAML 实测：

```python
>>> yaml.safe_load('port:8080')
'port:8080'
```

整份文件解析出来是一个字符串 `'port:8080'`，不是 `{'port': 8080}`。这个错误不会报错，只是配置项「没生效」，所以不好查。

### 嵌套：靠缩进

值本身也可以是一个映射，下一层的键往右缩进：

```yaml
server:
  port: 8080
  servlet:
    context-path: /api
```

这表示 `server` 下面有 `port` 和 `servlet` 两个键，`servlet` 下面又有 `context-path`。展平成 properties 就是 `server.port` 和 `server.servlet.context-path`，[[Spring Boot]] 读 YAML 时内部做的就是这个展平。

缩进有三条规则：

1. **只能用空格，不能用 Tab。** 这是 YAML 规范的硬性规定，用 Tab 缩进会直接解析失败：

   ```text
   while scanning for the next token
   found character '\t' that cannot start any token
     in "<unicode string>", line 2, column 1:
         	port: 8080
         ^
   ```

   编辑器里把 Tab 设成「插入空格」就不会碰到这个问题。

2. **缩进几个空格都行，但同一层必须对齐。** 习惯上用 2 个。

3. **多缩进或少缩进一格，结构就变了。** 下面 `host` 多缩进了一格：

   ```yaml
   server:
     port: 8080
      host: x
   ```

   解析器会认为 `host: x` 是 `8080` 这个值的延续，然后报错：

   ```text
   mapping values are not allowed here
     in "<unicode string>", line 3, column 8:
          host: x
              ^
   ```

   看到 `mapping values are not allowed here`，先去报错那一行检查缩进和冒号。

### 序列：列表

每一项用 `- `（短横线加空格）开头，同一个列表的各项缩进对齐：

```yaml
servers:
  - dev.example.com
  - prod.example.com
```

解析结果是 `{'servers': ['dev.example.com', 'prod.example.com']}`。

列表的每一项也可以是映射，这就是「对象列表」：

```yaml
users:
  - name: Tom
    age: 18
  - name: Jerry
    age: 20
```

结果是两个对象：`[{'name': 'Tom', 'age': 18}, {'name': 'Jerry', 'age': 20}]`。读法是：`-` 开始一个新元素，和 `name` 对齐的 `age` 属于同一个元素。

### 行内写法

映射和序列都有一种写在一行里的「流式」写法，长得和 JSON 一样：

```yaml
ports: [80, 443]
point: {x: 1, y: 2}
```

YAML 1.2 规范把自己设计成 JSON 的超集，合法的 JSON 文本基本都能直接当 YAML 解析。短列表用行内写法，长的或者嵌套深的用缩进写法，可读性更好。

## 标量：字符串、数字、布尔值、空值

### 字符串：大多数时候不用引号

```yaml
name: 图书管理系统
url: jdbc:mysql://localhost:3306/ssm_db
```

不加引号的字符串叫**普通标量**（plain scalar）。需要引号的情况有两种：值会被误判成别的类型（下一节讲），或者值以 YAML 的特殊符号开头，比如 `@`、`*`、`&`、`{`、`[`。

两种引号的区别在于转义：

```yaml
a: 'it''s'
b: "tab\there"
c: 'tab\there'
```

实测结果：

```python
{'a': "it's", 'b': 'tab\there', 'c': 'tab\\there'}
```

- **双引号**支持 `\t`、`\n` 这类转义，`b` 里的 `\t` 变成了真正的制表符
- **单引号**里反斜杠就是反斜杠，`c` 里保留了 `\` 和 `t` 两个字符；单引号本身用两个单引号 `''` 表示

### 空值

`~`、`null`、冒号后面什么都不写，三种写法都解析成空值：

```yaml
a: ~
b:
c: null
```

结果是 `{'a': None, 'b': None, 'c': None}`。注意 `b:` 这种写法：你本想写个值结果忘了，解析器不会提醒，它就是空值。

### 注释

`#` 开始注释，到行尾结束。`#` 前面必须有空格（或者在行首），否则它只是字符串的一部分：

```yaml
msg: hello # 这是注释
url: http://a.com/#top
```

结果是 `{'msg': 'hello', 'url': 'http://a.com/#top'}`，URL 里的 `#top` 被完整保留。

### 多行字符串

两种块写法，区别在于换行保不保留：

```yaml
literal: |
  line1
  line2
folded: >
  line1
  line2
```

结果：

```python
{'literal': 'line1\nline2\n', 'folded': 'line1 line2\n'}
```

`|` 原样保留换行，适合写脚本、SQL、证书这类换行有意义的内容；`>` 把换行折叠成空格，适合写一段很长的说明文字。GitHub Actions 里多行的 `run:` 命令用的就是 `|`。

## 类型猜测：最容易踩的坑

不加引号的值，解析器会按规则判断它是什么类型。问题是 YAML 有两个版本在用，判断规则不一样：

- **YAML 1.1**（2005 年）：布尔值有 `yes`/`no`/`on`/`off` 等一大串写法，以 `0` 开头的整数按八进制解析
- **YAML 1.2**（2009 年）：布尔值只认 `true`/`false`，去掉了上面这些容易误判的规则

新规范出来很多年了，但不少常用解析器仍然按 1.1 的规则判断类型。Java 生态里最常用的 SnakeYAML 就是其中之一，它的源码里布尔值的匹配规则是：

```java
public static final Pattern BOOL = Pattern
    .compile("^(?:yes|Yes|YES|no|No|NO|true|True|TRUE|false|False|FALSE|on|On|ON|off|Off|OFF)$");
```

[[Spring Boot]] 读 `application.yml` 用的就是 SnakeYAML。

### 同一份文件，两种结果

用两个 Python 解析器实测：PyYAML 按 1.1 规则，ruamel.yaml 默认按 1.2 规则。

```yaml
enabled: yes
country: NO
switch: on
password: 0123
version: 1.10
```

| 键 | YAML 1.1（PyYAML） | YAML 1.2（ruamel.yaml） |
| --- | --- | --- |
| `enabled: yes` | `True` | `'yes'` |
| `country: NO` | `False` | `'NO'` |
| `switch: on` | `True` | `'on'` |
| `password: 0123` | `83` | `123` |
| `version: 1.10` | `1.1` | `1.1` |

逐个看：

- **`country: NO`**：本意是挪威的国家代码，按 1.1 规则读成了布尔值 `False`。这个坑常被叫作「挪威问题」
- **`password: 0123`**：1.1 规则下，`0` 开头、后面全是 0~7 的数字是八进制，`0123` 等于十进制 83。按 1.2 规则读成 123，开头的 0 也丢了。**两种规则都拿不到原样的 `"0123"`**
- **`version: 1.10`**：两个版本都把它当浮点数，`1.10` 和 `1.1` 是同一个数，末尾的 0 没了。版本号 `1.10` 和 `1.1` 本来是两个不同的版本

八进制规则还有一个反直觉的地方：`0129` 里有 9，不是合法的八进制数，于是它不会被当成数字，而是保留成字符串 `'0129'`。同样是「0 开头的密码」，`0123` 变成 83，`0129` 原样保留。所以这类问题在一部分数据上测不出来，换一个值才出错。

### 解决办法：加引号

```yaml
country: "NO"
password: "0123"
version: "1.10"
```

加了引号就一定是字符串，两种规则都不会再猜。实测 `p: "0123"` 解析结果是 `'0123'`。

可以记一条简单的规则：**值是给人看的编号、代码、密码、版本号，而不是用来计算的数，就加引号。**

## 多文档：用 `---` 分隔

一个文件里可以放多份独立的文档，用单独一行的 `---` 分隔：

```yaml
a: 1
---
a: 2
```

按多文档读取，得到两个独立的映射 `[{'a': 1}, {'a': 2}]`，第二份不会覆盖第一份。Spring Boot 用这个特性在一个文件里写多套环境配置，见 [[Spring Boot#多环境]]。

## 锚点与合并：复用一段配置

几段配置大部分相同、只差一两项时，可以用**锚点**（`&名字`）给一段内容起名，用**别名**（`*名字`）引用它，再用合并键 `<<` 把它展开进来：

```yaml
base: &base
  timeout: 30
  retries: 3
dev:
  <<: *base
  retries: 5
```

结果：

```python
{'base': {'timeout': 30, 'retries': 3}, 'dev': {'timeout': 30, 'retries': 5}}
```

`dev` 先继承了 `base` 的两个键，再用自己的 `retries: 5` 覆盖。合并键 `<<` 是 YAML 1.1 时代的扩展类型，不是每个工具都支持，用之前先确认目标工具认不认。

## 重复的键

同一个映射里写了两次同一个键：

```yaml
a: 1
a: 2
```

各家处理不一样：PyYAML 静默保留后一个，结果是 `{'a': 2}`；ruamel.yaml 直接报 `DuplicateKeyError`。Spring Boot 加载配置文件时明确关闭了重复键（源码里是 `loaderOptions.setAllowDuplicateKeys(false)`），所以 `application.yml` 里有重复键时应用启动会失败。

最常见的情况是配置文件写长了，在文件末尾又写了一遍 `spring:`，想往里面补一项。正确做法是找到已有的 `spring:`，在它下面加。

## 参考

- [YAML 1.2.2 规范](https://yaml.org/spec/1.2.2/)
- [YAML 1.1 布尔类型定义](https://yaml.org/type/bool.html)
- [SnakeYAML Resolver 源码](https://github.com/snakeyaml/snakeyaml/blob/master/src/main/java/org/yaml/snakeyaml/resolver/Resolver.java)：布尔、整数的隐式类型匹配规则
- [Spring Boot：Working With YAML](https://docs.spring.io/spring-boot/reference/features/external-config.html#features.external-config.yaml)
