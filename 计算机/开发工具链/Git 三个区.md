---
tags: [类型/概念, 技术/Git]
aliases: [Git 分区, 工作区, 暂存区, 版本库, index, staging area, working tree, git diff, git status, git add, 跟踪与未跟踪]
created: 2026-08-27
updated: 2026-08-27
---
> Git 把你的改动分三个地方存放——工作区、暂存区、版本库，`add`、`commit`、`restore` 这些命令做的事情，全都是把内容在这三个地方之间搬来搬去。

新手用 Git 时最常撞上的几件怪事，几乎都是同一个原因：

- 明明改了文件，`git commit` 却说没东西可提交
- `git add` 之后又改了两行，提交进去的却是改之前的版本
- 新建的文件在 `git status` 里显示成一堆问号

这些都不是 bug。它们全都源于同一件事：**你眼里的「文件」在 Git 眼里同时有三份**。搞懂这三份分别在哪、什么命令动哪一份，上面的怪事就都变成理所当然的了。

## 先说清楚三个词

后面会反复用到，先定义好。

**提交（commit）**：给整个项目拍一张快照存档。注意它不是「保存这个文件的改动」，而是「记下此刻整个项目长什么样」。每张快照存下来之后**再也不能修改**，这是 Git 敢让你随便折腾的底气——历史是只读的。

**哈希（hash）**：每个提交的身份证号，长这样 `d72c8c94386fdbbf9191019b93586b8424e21eb6`，40 个十六进制字符。日常只用前 7 位就够区分，比如 `d72c8c9`。你在各种命令里看到的这种乱码，都是在指某一个提交。

**跟踪（tracked）**：Git 是否知道这个文件的存在。**只有被 `git add` 过至少一次的文件才算被跟踪。** 新建的文件在你 `add` 它之前，Git 完全不管它，`git status` 里会标成 `??`。这解释了上面第三件怪事。

## 三个区分别是什么

接着刚才「拍快照」的说法：**工作区**是现场，**暂存区**是你决定这张照片里要出现哪些东西，**版本库**是已经洗出来存档的照片。

| 区 | 英文名 | 实际在哪 | 里面是什么 |
| --- | --- | --- | --- |
| 工作区 | working tree | 你的项目文件夹 | 你正在用编辑器改的那些文件，也就是你打开就能看到的 |
| 暂存区 | index / staging area | `.git/index` 这个文件 | 「下次提交要包含什么」的一份完整清单 |
| 版本库 | repository | `.git/objects/` | 已经拍好的所有快照，只读 |

三个区都在你自己电脑上，`.git` 这个隐藏文件夹里装着后两个。**删掉 `.git` 文件夹，你的代码文件还在（工作区），但所有历史就没了。**

暂存区的正式名字是 **index**，`staging area` 是它的另一个叫法，Git 的文档和报错信息里两个词混着用，看到哪个都是指同一样东西。中文教程里叫「暂存区」「索引」「缓存区」的，也都是它。

一个容易误会的点：**暂存区里存的是一份完整快照，不是一个「待办文件列表」。** 就算你只 `git add` 了一个文件，index 里记的仍然是「整个项目此刻应该是什么样」。这个区别在后面理解 `git diff --staged` 时用得上。

有些教程会讲「四个区」，把远程仓库算第四个。那是另一回事：前三个区都在你的电脑上，远程仓库在服务器上，`push`/`pull` 和 `add`/`commit` 不是一类操作。本篇只讲本地这三个。

## 手把手走一遍

光看定义没用，跟着敲一遍最快。下面每一步都看一眼 `git status`，观察文件在三个区之间移动。

**第 0 步：建个仓库，提交一个初始文件。**

```bash
mkdir demo && cd demo
git init
echo "第一行" > a.txt
git add a.txt
git commit -m "第一次提交"
```

现在三个区完全一致，`git status` 是干净的。

**第 1 步：改一下文件，先不 add。**

```bash
echo "第二行" >> a.txt
git status --short
```

```text
 M a.txt
```

`M` 前面有个空格，位置很重要，等下解释。此刻：工作区有两行，暂存区和版本库都还是一行。

**第 2 步：`git add`，把改动放进暂存区。**

```bash
git add a.txt
git status --short
```

```text
M  a.txt
```

`M` 挪到前面去了。此刻：工作区和暂存区都是两行，版本库还是一行。

**第 3 步：先别提交，再改一次文件。**

```bash
echo "第三行" >> a.txt
git status --short
```

```text
MM a.txt
```

两个 `M` 同时出现了。此刻三个区**内容各不相同**：工作区三行，暂存区两行，版本库一行。这就是三个区最直观的样子。

**第 4 步：提交，看看到底提交了什么。**

```bash
git commit -m "第二次提交"
git show HEAD:a.txt
```

输出只有**两行**，不是三行。因为 `commit` 只看暂存区，第三行你还没 `add`，它没资格进这次快照。提交完 `git status --short` 仍然显示 ` M a.txt`，那个剩下的改动就是第三行。

这一步就是开头说的第二件怪事。它不是 Git 出错，是暂存区语义的必然结果。

## 为什么要多这么一层

直接「改完就提交」也能用，多这一层换来的是**把「提交的内容」和「你干活的过程」分开**。

真实写代码的过程是乱的。你本来在修一个 bug，顺手改了个难看的变量名，又发现文档里参数写错了也一并改掉。如果提交必须包含工作区的全部改动，那历史里就会全是「修了 A，顺便还有 B 和 C」这种大杂烩提交。等到半年后出问题要查「这行是谁为什么改的」，或者想把其中一个修复单独摘出来给另一个分支用（见 [[Git 分支与合并]] 里的 `cherry-pick`），你会发现根本摘不出来——它和另外两件事焊死在一个提交里了。

有了暂存区，同样一堆乱改动可以拆成几个干净的提交：

```bash
git add src/parser.go
git commit -m "修复解析空行时的越界"

git add docs/README.md
git commit -m "更新: 文档里过期的参数说明"
```

如果两处无关的改动在**同一个文件**里，还能按代码块拆。`-p` 是 patch 的意思，Git 会把改动切成小块逐块问你要不要：

```bash
git add -p
```

对每一块回答 `y`（要）或 `n`（不要），就能把一个文件里的改动分进两个提交。这是暂存区最能体现价值的用法。

## 命令在三个区之间搬什么

理解了三个区，命令就不用背了——每个命令只是规定了「从哪搬到哪」：

| 命令 | 方向 | 白话 |
| --- | --- | --- |
| `git add <文件>` | 工作区 → 暂存区 | 这个改动我要，放进下次提交 |
| `git commit` | 暂存区 → 版本库 | 把暂存区的内容拍成快照存档 |
| `git restore --staged <文件>` | 版本库 → 暂存区 | 后悔了，从下次提交里撤出来（文件内容不动） |
| `git restore <文件>` | 暂存区 → 工作区 | 我这次改废了，恢复成没改的样子 |
| `git commit -a` | 工作区 → 版本库 | 跳过 add 直接提交（只管已跟踪的文件） |

两个提醒：

`git restore <文件>` 会**直接丢弃**你的改动，且没有回收站——那些改动从没进过 Git，任何后悔药都救不回来。敲之前确认文件名。

`git commit -a` 不包含未跟踪的新文件。新建的文件永远要先 `git add` 一次，`-a` 帮不了你。

`git reset` 也在这张图里，但它还会移动分支指针，作用范围更大，单独放在 [[Git 撤销操作]] 里讲。

`git restore` 和 `git switch` 是后来才加的命令，用来接替 `git checkout` 身上两类完全不相干的活——老的 `checkout` 既能切分支又能丢弃文件改动，是历史包袱，也是新手最容易误伤自己的地方。日常用 `restore`/`switch`，语义清楚得多。

有个前提要知道：这两个命令的 man page 至今（Git 2.50.1）仍然标着 `THIS COMMAND IS EXPERIMENTAL. THE BEHAVIOR MAY CHANGE.`。手工敲没问题，写进要长期维护的脚本时留意一下这行字。

## git status 怎么读

短格式最省事，关键是知道那两个字符各代表什么：

```bash
git status --short
```

**第一列 = 暂存区相对版本库的状态，第二列 = 工作区相对暂存区的状态。**

换成白话：**第一列是「已经 add 了的」，第二列是「还没 add 的」**。记住这个，符号就不用背：

```text
M  f.txt    改动已 add，工作区没有新改动
 M f.txt    改动还没 add
MM f.txt    add 过一次，之后又改了（就是刚才第 3 步的状态）
A  x.txt    新文件已 add
?? new.txt  未跟踪，Git 还不认识这个文件
UU f.txt    冲突了，两边都改了同一处（见 [[Git 分支与合并]]）
```

长格式 `git status` 啰嗦，但它会**直接告诉你该敲什么命令**，新手其实更该用这个：

```text
Changes to be committed:
  (use "git restore --staged <file>..." to unstage)
	modified:   a.txt

Changes not staged for commit:
  (use "git add <file>..." to update what will be committed)
  (use "git restore <file>..." to discard changes in working directory)
	modified:   a.txt
```

`Changes to be committed` 就是暂存区里的东西，`Changes not staged for commit` 就是工作区里还没 add 的。括号里那行是 Git 给你的现成命令。不确定该干什么的时候先跑 `git status` 读提示，比凭印象敲命令安全得多。

## git diff 的三种问法

`git diff` 常用的就三个形态，区别**只在于比较哪两个区**。还是用刚才那个三区内容各不相同的例子（版本库是 `line2`+`line3`，暂存区是 `STAGED`+`line3`，工作区是 `STAGED`+`WORKTREE`）：

**`git diff`** —— 比的是工作区和暂存区，回答「我改了但**还没 add** 的是哪些」：

```diff
 line1
 STAGED
-line3
+WORKTREE
```

**`git diff --staged`** —— 比的是暂存区和版本库，回答「我 add 了、**下次提交会进去**的是哪些」。`--cached` 是同义词，两个都能用：

```diff
 line1
-line2
+STAGED
 line3
```

**`git diff HEAD`** —— 比的是工作区和版本库，回答「相对上次提交，我**总共**改了什么」：

```diff
 line1
-line2
-line3
+STAGED
+WORKTREE
```

前两个的输出拼起来正好等于第三个，这不是巧合，是三个区首尾相接的结果。

读 diff 输出时，`-` 开头的行是删掉的，`+` 开头的是新增的，前面带空格的是没变、拿来给你定位的上下文。修改一行会显示成「删一行 + 加一行」。

**提交前的标准动作是 `git diff --staged`**，因为它显示的才是真正会被提交的内容。直接敲 `git diff` 看到的是你还没 add 的部分，正好是不会被提交的那些。

## 常见坑

**`git add` 之后再改文件，提交进去的是 `add` 那一刻的内容。**

```bash
echo ADDED > f.txt
git add f.txt
echo CHANGED_AFTER_ADD > f.txt   # add 之后又改了
git commit -m "提交"
git show HEAD:f.txt              # 输出 ADDED，不是 CHANGED_AFTER_ADD
```

前面走查的第 3、4 步就是这个。养成提交前看一眼 `git diff --staged` 的习惯，这个坑基本就绝迹了。

**`.gitignore` 对已经跟踪的文件不起作用。**

`.gitignore` 只负责一件事：决定**未跟踪**的文件要不要显示、要不要被 `git add` 捎带上。文件一旦进过版本库，加进 `.gitignore` 之后照样被跟踪：

```bash
echo "f.txt" > .gitignore
echo IGNORED_ATTEMPT > f.txt
git status --short    # 仍然输出  M f.txt
```

要让 Git 真的撒手不管，得先把它从索引里踢出去。`--cached` 表示只从 Git 的记录里删，**你磁盘上的文件保留**：

```bash
git rm --cached f.txt
```

这也解释了为什么密钥文件误提交之后，光加进 `.gitignore` 是不够的——它还留在历史的每一张快照里，得另外处理。

**`.git` 文件夹别手贱删。** 工作区的文件删了还能重写，`.git` 没了就是全部历史没了，而且没有任何 Git 命令能救——因为要救你的那些命令，它们的数据本身就在 `.git` 里。

## 参考
- `git help glossary`，其中 index、working tree 的官方定义
- `git help status`，短格式每个字符的完整含义表

## 待补充
- `.git/index` 的二进制格式，以及用 `git ls-files --stage` 直接读它的方法
- 稀疏检出（sparse-checkout）会怎么影响三个区的对应关系
