# dsh-client-sales-coach

DSH Host 插件：把「客户聊天教练」注册成会话技能。

装上之后，新会话的技能目录里会出现 `client-sales-coach`，模型在遇到客户聊天记录、
销售流程问题时自动加载；技能正文来自包内 `skills/client-sales-coach/SKILL.md`，
9 个方法论文件在 `references/` 下按需读取。

## 结构

```
dsh-plugin/
├── package.json            # dsh.bundle.patch 指向 cordis.patch.yml
├── cordis.patch.yml        # 插入 client-sales-coach 行
├── lib/index.js            # 用 ctx.skills.register() 注册技能
├── locale/en.json|zh.json  # 插件面板标题与描述
├── icon.svg                # 插件图标
└── skills/client-sales-coach/
    ├── SKILL.md            # 技能正文（改这里，技能立即变化，无需改代码）
    └── references/*.md     # 9 个方法论文件
```

## 安装

在 DSH 会话里用插件管理器安装这个目录（绝对路径）：

```text
plugin_manager install_bundle target = <本地路径>/客户聊天教练-skill/dsh-plugin
```

安装后确认：

- 技能目录出现 `client-sales-coach`；
- 设置 → 插件里出现「客户聊天教练」，图标与描述正常。

## 更新

- 改正文：编辑 `skills/client-sales-coach/SKILL.md` 或 `references/*.md`，重装一次即可生效。
- 卸载：`plugin_manager remove_bundle target = dsh-client-sales-coach`。

## License

MIT
