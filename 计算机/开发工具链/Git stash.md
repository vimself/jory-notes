---
tags: [类型/实践, 技术/Git]
aliases: [git stash, 贮藏, 暂存改动, 储藏, stash pop, stash apply, 保存工作现场]
created: 2026-08-28
updated: 2026-08-28
---
> `git stash` 把手头没做完的改动打包收进一个抽屉，让工作区立刻变干净，等你忙完别的再原样取回来。

## 它解决什么问题

你正在 `feature` 分支上改一个功能，改到一半，代码处于「跑不起来」的状态。这时候同事让你切到 `main` 看个东西。

直接切分支，Git 大概率会拦住你：你的改动和目标分支的内容冲突，切过去会覆盖掉你没保存的东西。

摆在你面前的三条路：

1. 硬提交一个「WIP，别看」的半成品提交 —— 脏了历史，回头还得清理
2. 手动把改动复制到别处 —— 累且容易漏
3. **`git stash`** —— 一条命令收起来，切分支，回来再一条命令放回去

第三条就是它存在的理由。

## 最简单的用法

```bash
git stash push -m "登录页改一半"
```

```text
Saved working directory and index state On main: 登录页改一半
```

敲完之后 `git status` 立刻变干净，你的改动被收进了一个栈里。忙完之后取回来：

```bash
git stash pop
```

改动原样回到工作区，就像没走开过。

`-m` 后面的说明可以不写，但**强烈建议写**。stash 堆到三四个之后，`stash@{0}`、`stash@{1}` 这种编号完全看不出是什么。

## 查看抽屉里有什么

```bash
git stash list
```

```text
stash@{0}: On main: 登录页改一半
```

`stash@{0}` 是最新的一个，编号越大越旧。**新存进来的永远是 `{0}`**，老的往后挪——它是个栈。

看某一条具体改了什么：

```bash
git stash show stash@{0}          # 只看统计
git stash show -p stash@{0}       # 看完整 diff
```

## pop 和 apply 的区别

这两个都能把改动放回来，区别只有一个：**用完之后那条记录还在不在**。

```bash
git stash apply    # 放回来，记录保留
git stash pop      # 放回来，记录删掉
```

实测对比。`apply` 之后列表里还在：

```bash
git stash apply
git stash list
```

```text
stash@{0}: On main: 测试
```

`pop` 之后列表空了，终端还会告诉你丢弃了哪条：

```text
Dropped refs/stash@{0} (15aeac81cefb17d3317023cc3507dbc832da1f0f)
```

**日常用 `pop`。** 什么时候用 `apply`：你想把同一份改动应用到两个不同分支上，或者不确定能不能干净地放回去，想留个底。

手动删除记录：

```bash
git stash drop stash@{0}     # 删一条
git stash clear              # 全清空，慎用
```

## 最大的坑：默认不管未跟踪文件

**`git stash` 只收「已跟踪文件」的改动。你新建的文件它不碰。**

这个坑很隐蔽，因为它不报错，只是悄悄把新文件留在原地。实测：

```bash
# stash 前
 M f.txt
?? new.txt
```

```bash
git stash push -m "半成品"
```

```bash
# stash 后 —— new.txt 还在！
?? new.txt
```

如果你以为工作区已经干净了，切过去可能会带着这个文件跑，或者以为改动都收好了结果丢了新文件。

加 `-u`（`--include-untracked`）才会一起收：

```bash
git stash push -u -m "含未跟踪"
```

这次工作区真的干净了，`ls` 只剩下已跟踪的 `f.txt`，`new.txt` 也被收进抽屉，`pop` 之后两个文件一起回来。

还有个 `-a`（`--all`），连**被 `.gitignore` 忽略的文件**也一起收。基本用不上，除非你要彻底清空工作区。

记不住的话有个简单策略：**默认就打 `git stash push -u`**，除非你明确知道不想带上新文件。

## 其他常用形态

**只 stash 一部分。** 跟 `git add -p` 一样按代码块挑：

```bash
git stash push -p
```

**只 stash 某几个文件：**

```bash
git stash push -m "只收这俩" src/a.js src/b.js
```

**stash 完直接开个新分支。** 适合「本来在 `main` 上改，改着改着发现该开个分支」的情况：

```bash
git stash branch 新分支名
```

它会新建分支、切过去、把 stash 应用上、并删掉那条记录，一步到位。

## 冲突了怎么办

`pop` 的时候目标分支已经改过同一块地方，会冲突。处理方式和普通合并冲突完全一样（见 [[Git 分支与合并]]）：编辑文件、删掉冲突标记、`git add`。

有个细节要注意：**`pop` 遇到冲突时，那条 stash 记录不会被删除。** Git 怕你解冲突解砸了没了退路。所以冲突解决完，确认没问题之后，需要你自己删：

```bash
git stash drop
```

## 它和其他命令的关系

**别把 stash 当长期仓库用。** 它是临时抽屉，适合放几分钟到几小时的东西。理由：

- stash 记录是**纯本地的**，推不到远程，换台电脑就没了
- 列表里堆了十几条之后，你根本想不起 `stash@{7}` 是什么
- 它不属于任何分支，`git log` 里看不见，容易彻底遗忘

**要放超过一天，就开个分支提交上去**，哪怕提交信息写「WIP」。分支能推远程、能起名字、能被别人看到。

和 [[Git 撤销操作]] 的分工：stash 是「先放一边，等下还要」，撤销是「不要了」。手头改动确定不要，直接 `git restore`，不用绕 stash。

## 参考
- `git help stash`，全部子命令与选项
