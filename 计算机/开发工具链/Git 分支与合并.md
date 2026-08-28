---
tags: [类型/概念, 技术/Git]
aliases: [Git 分支, Git 合并, git branch, git switch, git merge, git rebase, 变基, squash merge, 压缩合并, fast-forward, 快进合并, 三方合并, 共同祖先, 合并冲突, git cherry-pick, 拣选, git pull --rebase, rerere, HEAD, 远程跟踪分支, 分离头指针]
created: 2026-08-27
updated: 2026-08-27
---
> 分支只是一个指向某个提交的指针，所以新建和切换几乎不花时间；把两条分支的工作并到一起有 merge、rebase、squash merge 三条路，它们的区别不在能不能合上，而在**合完之后历史长什么样**。

## 分支解决什么问题

先看没有分支会怎样。

你在做一个要写三天的新功能，写到第二天，线上冒出一个紧急 bug 要立刻修。现在你的代码是半成品，改到一半根本不能上线。你只能：把半成品复制一份到别的文件夹，把当前目录改回上线的样子，修完 bug，再把半成品挪回来。手动、易错、还容易漏。

分支就是把这套操作变成两条命令。你可以让「三天的新功能」和「线上稳定版本」**同时存在于同一个仓库里**，随时切换，互不干扰。修 bug 时切到稳定分支，改完切回来，你的半成品原样还在。

这也是多人协作的基础：每个人在自己的分支上干活，谁都不会把谁的半成品带上线，最后再统一合并。

## 分支其实就是一个指针

新手最容易脑补的画面是：新建分支 = 把整个项目复制一份。**不是的。** 如果是复制，大仓库开分支得等半天，实际上它是瞬间完成的。

真相是：**一个分支就是一个记着某个提交哈希的文件**。不信可以直接看：

```bash
cat .git/refs/heads/feature
```

```text
d72c8c94386fdbbf9191019b93586b8424e21eb6
```

整个文件 41 字节——40 个十六进制字符加一个换行，就这些。所谓「新建分支」，就是新写一个这样的小文件。

想通这点，很多事情就顺了：分支不占空间，所以**该开就开，不用犹豫**；分支删了也不心疼，因为提交本身还在，删的只是那个小文件（找回办法见 [[Git 撤销操作]] 的 reflog 一节）。

### HEAD：你现在站在哪

还有个特殊指针叫 `HEAD`，表示「我当前在哪个分支上」。它存的通常不是哈希，而是一个指向分支的引用：

```bash
cat .git/HEAD
```

```text
ref: refs/heads/main
```

切换分支，改的就是这个文件。

现在可以把「提交」这件事说透了。你敲 `git commit` 时，Git 做的是：造一个新的快照对象，然后**把 `HEAD` 所指向的那个分支文件里的哈希，改成新提交的哈希**。分支「往前走了一步」，本质就是这么回事。

顺带解释一个新手常撞见的吓人提示。如果 `HEAD` 里存的直接是一个哈希、而不是 `ref:` 开头的引用，你就处在**分离头指针**（detached HEAD）状态——你停在某个提交上，但没有任何分支指着这里。

这种状态下的提交不属于任何分支，一旦切走就从 `git log` 里消失了（`git reflog` 还能捞回来）。想保住这些提交，切走之前先给它安一个分支：

```bash
git switch -c 新分支名
```

### 日常命令

```bash
git switch <分支>            # 切换到已有分支
git switch -c <分支>         # 新建并切换（-c 是 create）
git branch                  # 列出本地分支
git branch -vv              # 多显示每个分支跟踪的远程分支、领先/落后几个提交
git branch -d <分支>         # 删除分支，还没合并的话会拒绝，保护你
git branch -D <分支>         # 强制删除，确定不要了再用
```

`git switch` 和老命令 `git checkout` 的关系见 [[Git 撤销操作]]，新写的东西用 `switch`。

### 远程跟踪分支

`origin/main` 这种带斜杠的名字，是**远程跟踪分支**。它不是远程仓库本身，而是「**我上次跟远程通信的时候，远程的 main 停在哪**」的一份本地记录。

关键点：**它不会自己更新。** 同事推了新代码，你的 `origin/main` 不会自动变，得你主动去取：

```bash
git fetch                     # 只更新 origin/* 的记录，不碰你的分支和工作区
git push -u origin feature    # 首次推送，并建立跟踪关系（-u 只需要第一次加）
```

`git fetch` 是完全安全的操作——它不改你的工作区，也不改你的本地分支，只是把远程的最新情况取回来。搞不清状况时先 `fetch` 再 `git branch -vv` 看看差多少，比直接 `pull` 稳妥得多。

`git pull` 则等于 `git fetch` 加一步合并，它**会**动你的分支，后面 rebase 一节会细说。

## 把两条分支并到一起：三条路

设定统一一下：`feature` 从 `main` 分出去之后，两边各自都有了新提交，现在要把 `feature` 的工作并回 `main`。

三种做法都能把代码合上，产出的历史却完全不同：

| 方式 | 历史形状 | 原来的提交 | 适合什么场合 |
| --- | --- | --- | --- |
| `merge` | 保留分叉，多一个合并提交 | 原样保留 | 公共分支；想留下真实的协作过程 |
| `rebase` | 拉成一条直线 | **哈希全变** | 自己的功能分支，推之前整理用 |
| `squash merge` | 一条直线，整个分支压成一个提交 | 压成一个新的 | PR 合入主干，主干只留一行记录 |

下面逐个看。

### fast-forward：其实压根没合并

先看最简单的情况：**从分叉之后 `main` 一直没有新提交**，只有 `feature` 往前走了。

这时候「合并」根本不需要动脑子——`main` 落在后面，`feature` 就在它正前方的同一条线上。Git 只要把 `main` 这个指针往前挪到 `feature` 的位置就完事了。这叫**快进**（fast-forward）：

```text
Updating 0fc26db..463ae4f
Fast-forward
 f.txt | 2 ++
 1 file changed, 2 insertions(+)
```

结果是一条直线，完全看不出曾经开过分支：

```text
* 463ae4f feat commit 2
* b8be92c feat commit 1
* 0fc26db c1
```

**注意这里没有产生任何新提交**，只是指针挪了个位置。

有时候你希望「这里曾经有一个分支」这件事在历史里留下痕迹，就用 `--no-ff` 强制造一个合并提交：

```bash
git merge --no-ff feature -m "merge feature"
```

```text
*   a028dda merge feature
|\
| * 463ae4f feat commit 2
| * b8be92c feat commit 1
|/
* 0fc26db c1
```

反过来还有 `--ff-only`，意思是「只接受快进，如果需要造合并提交就直接报错退出」。用在「我这个分支必须是基于最新代码的，否则不准合」的场合。

### merge：三方合并

`main` 和 `feature` **都有**新提交时，指针挪不过去了，得真的合。

Git 的做法是找**共同祖先**——两条分支分家之前的最后一个共同提交。然后拿三个快照做比较：共同祖先、`main` 现在的样子、`feature` 现在的样子。因为参照了三个点，所以叫**三方合并**。

有了祖先当参照，Git 就能判断每一处改动是谁动的：祖先里是 A，`main` 还是 A、`feature` 变成 B，那就听 `feature` 的。两边都从 A 改成了不同的东西，Git 判断不了，才叫你来处理，也就是冲突。

合并成功时，Git 造一个**有两个父提交**的提交，这就是合并提交：

```text
Merge made by the 'ort' strategy.
```

`ort` 是现在的默认合并策略，日常不用管它。它从 v2.33.0 起接替 `recursive` 成为默认；`recursive` 在 v2.50.0 之后被重定向成了 `ort` 的同义词，现在两个名字指的是同一个实现。

**merge 最大的优点是不改写任何已有提交**，所以它是操作公共分支时唯一安全的选择。代价是分支一多，历史图会变得很密。

### rebase：把提交搬到新地基上

`rebase` 中文叫「变基」，base 就是「基底」——你这条分支是从哪个提交长出来的。变基就是**换一个地基重来**。

具体做法：把你分支上的提交一个个取下来，**到目标分支的最新位置上，重新做一遍**。

分叉时是这样：

```text
* 6dcc436 feat B
* c079308 feat A
| * be09198 main C
|/
* b52634b c1
```

在 `feature` 上执行 `git rebase main`：

```text
* 2c61e13 feat B
* fabe259 feat A
* be09198 main C
* b52634b c1
```

分叉消失了，历史成了一条直线，看起来就像你**一开始就是基于 `main C` 写的**。

**这里有个必须看懂的细节：`feat A` 的哈希从 `c079308` 变成了 `fabe259`。**

提交是只读的，搬不动，所以 Git 实际做的是照着原提交的内容**造了一批新提交**。内容一样，但在 Git 眼里它们是全新的、跟原来那批毫无关系的提交。

这就直接推出了那条最有名的规矩：

> **变基黄金法则：不要对已经推送、别人可能已经拉走的分支做 rebase。**

道理和 [[Git 撤销操作]] 里「为什么推过就不能改」是同一个：别人本地还留着旧哈希那批提交，你重写完强推上去，他下次 `pull` 就会看到同样的改动出现两遍，历史彻底乱掉。

**自己的功能分支，推之前整理成直线，没问题。公共分支不要碰。**

### git pull --rebase

这是 rebase 最日常的用法，值得单独说。

`git pull` 默认等于 `git fetch` + `git merge`。当远程有新提交、你本地也有新提交时，它会造一个合并提交。人一多、`pull` 一频繁，历史里就塞满了「Merge branch 'main' of github.com:...」这种毫无信息量的噪音提交。

改成变基方式，历史立刻干净：

```bash
git pull --rebase
```

它做的是：把远程的新提交取下来，然后把**你本地那几个还没推的提交**，重新接到远程最新位置的后面。

嫌每次都要打这个参数，可以设成默认（`pull.rebase` 的默认值是 `false`，也就是 merge）：

```bash
git config --global pull.rebase true
```

这里重写的只是**你本地还没推出去的提交**，没有违反黄金法则，所以设成默认通常是安全的。

### squash merge：整个分支压成一个提交

```bash
git merge --squash feature
git commit -m "squash: feature 全部改动"
```

`--squash` 的官方描述是：把工作区和暂存区弄成合并之后的样子，但**不提交、不移动 HEAD、也不记录合并关系**。所以你得自己再敲一次 `git commit`，而且产出的是一个**普通提交**，不是合并提交。执行时终端会提醒你：

```text
Squash commit -- not updating HEAD
```

GitHub 上 "Squash and merge" 按钮干的就是这件事。功能分支上那 20 个「改个错别字」「再改一下」的零碎提交，合进主干时压成干净的一个，主干历史一个 PR 一行，非常清爽。

**但它有个坑，很多人踩过：squash 之后，两条分支在 Git 眼里仍然是分叉的。**

```text
* 2c61e13 feat B                      <- feature 还停在原地
* fabe259 feat A
| * 53cd561 squash: feature 全部改动    <- main 上是个全新提交
|/
* be09198 main C
```

那个 squash 提交跟 `feat A`、`feat B` **没有任何父子关系**。Git 不知道它们是一回事，只知道 main 上凭空多了一堆改动。

由此推出两条实践：

**合入之后要把功能分支删掉，别在上面接着开发。** 继续用的话，下次再合并时 Git 会把已经合过的改动当成新改动重新算一遍，冲突能让你怀疑人生。

**长期存在的分支之间不要用 squash merge。** 比如 `develop` 合进 `main` 这种两边都要长期活着的，用普通 merge。squash 适合的是「合完就删」的短命功能分支。

## cherry-pick：只挑一个提交

场景：功能分支写到一半，顺手修了个 bug。这个修复主干现在就要，但整个功能还没写完，不能合。

`cherry-pick` 就是干这个的——从别的分支挑**单个提交**复制到当前分支：

```bash
git cherry-pick <提交哈希>
```

挑完之后看日志，同一条提交信息出现在两个地方，但**哈希不一样**：

```text
* 5fbadb8 顺手修的 bug        <- feature 上的原件
* 1d2e272 功能提交
| * 6459ca1 顺手修的 bug      <- main 上的副本，哈希不同
|/
* 954d555 c1
```

和 rebase 一样，**它是复制，不是移动**，原提交好好地留在原处。

这也意味着：以后把整条 `feature` 合过来时，这个改动会遇到「这边已经有了」的情况。多数时候 Git 能自己处理好，偶尔会冲突。

加 `-x` 会在提交信息里自动附一行来源，多人协作时很值得加上：

```bash
git cherry-pick -x <提交哈希>
```

```text
顺手修的 bug

(cherry picked from commit 5fbadb88e05ce010f8325dd20ef9829a75f45d98)
```

要挑连续的一串提交用 `A..B`，注意这个范围**不含 A、含 B**。中途冲突了，同样用 `--continue` / `--abort` 收尾。

## 合并冲突

冲突不像看上去那么麻烦，有两件事先说清楚。

**首先，冲突没那么容易发生。** 只有两边改了**同一个文件的相近位置**，Git 才会叫你。两个人改同一个文件的不同函数，Git 自己就合好了，你都不会知道。

**其次，冲突时 Git 会停下来等你，不会破坏任何东西。** 随时可以一键退回冲突前的状态。

### 冲突时会看到什么

```text
Auto-merging f.txt
CONFLICT (content): Merge conflict in f.txt
Automatic merge failed; fix conflicts and then commit the result.
```

Git 把两边的版本都写进了文件里：

```text
title
<<<<<<< HEAD
MAIN BODY
=======
FEATURE BODY
>>>>>>> feature
footer
```

读法：`<<<<<<<` 到 `=======` 之间是**当前分支**（HEAD）的版本，`=======` 到 `>>>>>>>` 之间是**被合进来那个分支**的版本。`>>>>>>>` 后面标着来源。

此时 `git status` 里这些文件是 `UU`，表示两边都改了。

### 让 Git 多告诉你一件事

默认的两段式标记有个问题：你只看到「两个结果」，看不到**原本是什么**，所以判断不了各方到底改了啥。

把冲突风格换成 `zdiff3`，中间会多出共同祖先的版本：

```bash
git config --global merge.conflictStyle zdiff3
```

```text
title
<<<<<<< HEAD
MAIN BODY
||||||| 1257b36
body
=======
FEATURE BODY
>>>>>>> feature
footer
```

现在一目了然：原文是 `body`，两边各自改成了不同的东西。有了中间这段，你才知道该保留什么。

`merge.conflictStyle` 的默认值是 `merge`（两段式）。这个设置基本是白拿的好处，建议改掉。

### 解决流程

1. `git status` 看哪些文件冲突了
2. 挨个打开编辑，**把 `<<<<<<<`、`=======`、`>>>>>>>` 这些标记行全部删掉**，留下你想要的内容。正确答案常常不是任何一方的原样，而是两边融合后的第三种写法
3. `git add <文件>`，用这个动作告诉 Git「这个我处理好了」
4. 收尾：merge 用 `git commit`，rebase 用 `git rebase --continue`，cherry-pick 用 `git cherry-pick --continue`

**任何时候想不干了，都能一键退回：**

```bash
git merge --abort
git rebase --abort
git cherry-pick --abort
```

退回去是干净的，不留痕迹。卡住了别硬扛，退回来重新想清楚往往更快。

提交前搜一遍有没有漏掉的标记，这是很常见的事故：

```bash
git diff --check
```

### 进阶：rebase 冲突时 ours 和 theirs 是反的

这条第一次遇到一定会懵，先知道有这回事，真撞上时回来看。

在 `feature` 上执行 `git rebase main` 发生冲突时：

```text
<<<<<<< HEAD
MAIN
=======
FEATURE
>>>>>>> 1d7a954 (feature 改)
```

**`HEAD` 那一侧是 `main`，不是你的 `feature`。**

原因回到 rebase 的原理：它是先切到 `main` 当地基，再把你的提交一个个重放上去。放到一半时，「当前状态」自然就是 main 加上已经放好的那部分，而「传进来的」才是你自己那个提交。

所以 rebase 期间 `--ours` 指的是上游（main），`--theirs` 指的是你的改动，跟 merge 时的直觉**正好颠倒**。凭 ours/theirs 做选择之前，先确认自己在哪种操作里。

好在 rebase 停下时，`git status` 会明确告诉你处境和出路：

```text
interactive rebase in progress; onto f65efe5
Last command done (1 command done):
   pick 1d7a954 feature 改
  (fix conflicts and then run "git rebase --continue")
  (use "git rebase --skip" to skip this patch)
  (use "git rebase --abort" to check out the original branch)
```

### rerere：同一个冲突只解一次

长期分支反复合并主干时，往往要一遍遍解同一个冲突，非常烦人。`rerere`（reuse recorded resolution，复用已记录的解法）会记住你上次怎么解的，下次自动套用：

```bash
git config --global rerere.enabled true
```

它**默认是关的**，必须显式打开。开了之后是纯赚，长期分支上省事很多。

## 怎么选

- **公共分支（main、develop）**：只用 `merge`。不 rebase，不 reset，不 amend
- **自己的功能分支**：推之前 `git rebase main` 整理成直线，顺便把冲突提前解决掉，而不是留到合并时
- **PR 合入主干**：看团队约定。想让主干一个特性一行，用 squash merge；想保留完整开发过程，用 merge
- **日常同步代码**：`git pull --rebase`，或者干脆把 `pull.rebase` 设成 `true`
- **拿不准的时候**：用 `merge`。它不改写历史，最坏结果只是历史图丑一点，不会伤到别人

## 参考
- `git help merge`，`--squash`、`--ff` 系列选项与各合并策略的权威描述
- `git help rerere`，记录与复用冲突解法的机制
- `git help everyday`，按角色组织的常用命令集

## 待补充
- 交互式变基 `git rebase -i`（reword / edit / squash / fixup / drop）值得单独成篇：[[Git 交互式变基]]
- `ort` 策略相对旧 `recursive` 实现上的具体差异
- 分支模型选型（Git Flow / GitHub Flow / trunk based）留给 [[Pull Request]] 一起讲
