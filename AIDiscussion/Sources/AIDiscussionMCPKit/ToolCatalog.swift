import Foundation
import AIDiscussionBridge

/// MCP 工具面：schema 定义 + 给模型的 `instructions`。
///
/// ## 设计取向
///
/// 工具描述是模型**唯一**的说明书。这里刻意把"为什么要角色互斥""什么场景不该用"
/// 写进描述，而不是只罗列参数 —— 否则模型会把讨论组当成"多问几个模型"来用，
/// 而这个工具的价值恰恰在于**被系统性质疑**。
public enum ToolCatalog {

    public static let serverName = "aidiscussion"
    public static let serverVersion = "1.0.0"

    // MARK: - 给模型的说明

    public static let instructions = """
    AI 议事会：把本机多个**已登录的 ChatGPT 账号**组成一个讨论组，让它们扮演立场互斥的
    角色，按「独立论述 → 交叉质询 → 收敛决策」走完议程，最后给你一个结论。

    ## 什么时候该用
    - 需要多角度权衡的**决策**（方案选型、取舍判断、风险评估、"到底选 A 还是 B"）。
    - 你希望自己的判断被**系统性质疑一次**，而不是找人附和。
    - 不适合查事实、写代码、做算术 —— 那些直接做就行，开讨论是浪费。

    ## 角色必须互斥（最重要）
    所有账号背后都是同一个模型。如果每个角色的设定都"客观全面"，讨论必然退化成
    互相附和。给每个成员写清楚两件事：**专门负责挑什么毛病** + **不许越界谈什么**。
    例：「成本专家」只估算时间/金钱/人力开销，明确禁止谈体验与技术优雅性。
    拿不准就用 discussion_roles 里的内置模板（它们已经按这个原则写死了立场）。

    ## 推荐流程
    1. `discussion_profiles` 看本机有哪些 Chrome Profile 可用于绑定（`directory` 与
       `suggestedIdentity` 就是要传的值）。不传 profile 时服务端会自动分配未占用的。
    2. `discussion_run` 一次跑完并直接拿到结论。它会阻塞到你拿到结果或超时。
    3. 预估超过 10 分钟的讨论，改用 `discussion_start` + `discussion_status` 轮询，
       避免客户端工具调用超时；结论用 `discussion_result` 取。
    4. 拿到结论后**继续你自己的工作**。需要某个成员的原话全文时，从
       discussion_result 的 utterances 里取，或调高 maxCharsPerUtterance。

    ## 出错时怎么办
    - `login_required`：某个成员没登录。让用户到 AIDiscussion 界面点「一键跳转登录」，
      或按返回的 loginURL 登录该 Profile，然后重试。
    - `accessibility`：app 没拿到辅助功能权限，先让用户在系统设置里授权。
    - `invalid_request`：按返回的 hint 改参数（多半是 Profile 不存在或账号标识缺失）。
    """

    // MARK: - 工具列表

    public static let tools: [MCPTool] = [
        discussionRun,
        discussionStart,
        discussionStatus,
        discussionResult,
        discussionCancel,
        roles,
        profiles,
        groups
    ]

    // MARK: - 讨论类

    private static var discussionRun: MCPTool {
        MCPTool(
            name: "discussion_run",
            title: "跑一场讨论并拿到结论",
            description: """
            用多个已登录账号跑完一整场讨论（独立论述 → 交叉质询 → 收敛），
            直接在返回值里给你最终结论。这是**阻塞调用**：不返回就一直等。

            participants 至少 2 位，每位必须有互斥的角色设定（role 或 preset），
            且各自绑定不同的 Chrome Profile（不给 profile 时服务端自动分配）。

            先调用 discussion_profiles 拿到可用的 Profile 名，能显著减少试错。
            预计超过 10 分钟的讨论请改用 discussion_start + discussion_status。

            返回：最终结论 + 每位成员的发言 + 账号审计（谁用哪个账号说的）。
            """,
            inputSchema: specSchema(includeTimeout: true, includeDisplayOptions: true)
        )
    }

    private static var discussionStart: MCPTool {
        MCPTool(
            name: "discussion_start",
            title: "异步起一场讨论",
            description: """
            参数与 discussion_run 相同，但**立即返回 jobId**，讨论在后台继续跑。

            适合长讨论（多轮、多成员）：拿到 jobId 后可以去做别的事，
            用 discussion_status 查进度，用 discussion_result 取结论。
            讨论跑在 AIDiscussion.app 里，所以你这边中断了讨论也不会停。
            """,
            inputSchema: specSchema(includeTimeout: false, includeDisplayOptions: false)
        )
    }

    private static var discussionStatus: MCPTool {
        MCPTool(
            name: "discussion_status",
            title: "查讨论进度 / 桥接状态",
            description: """
            带 jobId：返回该任务的进度（当前第几轮、谁在作答、已完成几条发言）。

            不带 jobId：返回桥接自身的状态 —— 包括 app 是否在跑、辅助功能权限是否已授予、
            可用 Profile 数、以及当前所有在跑的任务。怀疑"讨论卡住了"时先调这个。
            """,
            inputSchema: object([
                ("type", .string("object")),
                ("properties", object([
                    ("jobId", object([
                        ("type", .string("string")),
                        ("description", .string("discussion_start / discussion_run 返回的任务 id。省略则返回桥接总体状态。"))
                    ]))
                ])),
                ("required", .emptyArray)
            ])
        )
    }

    private static var discussionResult: MCPTool {
        MCPTool(
            name: "discussion_result",
            title: "取讨论结论",
            description: """
            取一个已完成任务的完整结果：最终结论、每轮每位成员的发言全文、账号审计。
            任务未结束时返回 busy 并附当前进度 —— 这不是错误，稍后再取即可。
            """,
            inputSchema: object([
                ("type", .string("object")),
                ("properties", object([
                    ("jobId", object([
                        ("type", .string("string")),
                        ("description", .string("discussion_start 返回的任务 id。"))
                    ])),
                    ("maxCharsPerUtterance", object([
                        ("type", .string("integer")),
                        ("description", .string("每条发言最长保留多少字符，超出截断。默认 2000，最小 200。")),
                        ("minimum", .int(200))
                    ]))
                ])),
                ("required", .array([.string("jobId")]))
            ])
        )
    }

    private static var discussionCancel: MCPTool {
        MCPTool(
            name: "discussion_cancel",
            title: "取消讨论",
            description: """
            取消一个正在跑的任务。已经收敛的发言不会被撤销（都落盘了），
            只是不再继续往下推进。对已结束的任务调用是幂等的，不算错误。
            """,
            inputSchema: object([
                ("type", .string("object")),
                ("properties", object([
                    ("jobId", object([
                        ("type", .string("string")),
                        ("description", .string("要取消的任务 id。"))
                    ]))
                ])),
                ("required", .array([.string("jobId")]))
            ])
        )
    }

    // MARK: - 目录类

    private static var roles: MCPTool {
        MCPTool(
            name: "discussion_roles",
            title: "内置角色模板",
            description: """
            列出内置角色模板（批判者 / 成本专家 / 乐观派 / 用户代言人 / 风险官 / 执行者）。

            每个模板的 rolePrompt 都**刻意只给一个维度并禁止越界**，用强制片面换取观点差异。
            可以直接把模板名填进 participants 的 preset 字段；要更贴合当前议题时，
            照着它的写法自己写 role（关键在于明确"不许谈什么"）。
            """,
            inputSchema: object([
                ("type", .string("object")),
                ("properties", .emptyObject),
                ("required", .emptyArray)
            ])
        )
    }

    private static var profiles: MCPTool {
        MCPTool(
            name: "discussion_profiles",
            title: "可用 Chrome Profile",
            description: """
            列出本机检测到的 Chrome Profile，以及每个 Profile 建议用的账号标识。

            传给成员的值：`profile` 用返回的 `directory`，`account` 用 `suggestedIdentity`。
            绑定时**必须一个 Profile 一位成员**（同一个 Profile 不能同时扮演两个角色，
            否则身份校验会直接拦下整场讨论）。
            """,
            inputSchema: object([
                ("type", .string("object")),
                ("properties", .emptyObject),
                ("required", .emptyArray)
            ])
        )
    }

    private static var groups: MCPTool {
        MCPTool(
            name: "discussion_groups",
            title: "已保存的讨论组",
            description: """
            列出用户在 AIDiscussion 界面里配置好的讨论组。

            想复用时，把组名填进 discussion_run / discussion_start 的 `group` 参数，
            再给一个 `topic` 覆盖议题即可 —— 角色与议程沿用界面里的配置，不用重新描述。
            """,
            inputSchema: object([
                ("type", .string("object")),
                ("properties", .emptyObject),
                ("required", .emptyArray)
            ])
        )
    }

    // MARK: - 复用的 schema 片段

    private static var participantSchema: JSONValue {
        object([
            ("type", .string("object")),
            ("properties", object([
                ("name", object([
                    ("type", .string("string")),
                    ("description", .string("显示名，如「批判者」。轮次里用这个名字引用发言人，必须唯一。"))
                ])),
                ("role", object([
                    ("type", .string("string")),
                    ("description", .string("角色设定。写清「专门负责挑什么毛病」+「不许越界谈什么」。与 preset 二选一，同时给时以 role 为准。"))
                ])),
                ("preset", object([
                    ("type", .string("string")),
                    ("description", .string("内置角色模板名，见 discussion_roles。"))
                ])),
                ("profile", object([
                    ("type", .string("string")),
                    ("description", .string("Chrome Profile 目录名，如 \"Profile 3\"。省略则由服务端自动分配一个未占用的。"))
                ])),
                ("account", object([
                    ("type", .string("string")),
                    ("description", .string("身份校验标识：该 Profile 登录的邮箱，或 Profile 显示名。省略则取 Profile 的显示名。"))
                ])),
                ("enabled", object([
                    ("type", .string("boolean")),
                    ("description", .string("是否参与本次讨论，默认 true。"))
                ]))
            ])),
            ("required", .array([.string("name")]))
        ])
    }

    private static var roundSchema: JSONValue {
        object([
            ("type", .string("object")),
            ("properties", object([
                ("kind", object([
                    ("type", .string("string")),
                    ("enum", .array([
                        .string("independentOpinion"),
                        .string("crossExamination"),
                        .string("convergence")
                    ])),
                    ("description", .string("独立论述（看不到别人）/ 交叉质询（能看到别人并反驳）/ 收敛决策。默认 crossExamination。"))
                ])),
                ("title", object([
                    ("type", .string("string")),
                    ("description", .string("轮次标题，显示用。省略则按 kind 自动生成。"))
                ])),
                ("instruction", object([
                    ("type", .string("string")),
                    ("description", .string("本轮额外指令，例如「请指出他人方案里成本最高的部分」。"))
                ])),
                ("visibility", object([
                    ("type", .string("string")),
                    ("enum", .array([.string("none"), .string("others"), .string("all")])),
                    ("description", .string("本轮能看到谁的发言。默认按 kind 推断：独立论述=none，其余=others。"))
                ])),
                ("speakers", object([
                    ("type", .string("array")),
                    ("items", object([("type", .string("string"))])),
                    ("description", .string("本轮的发言人名字数组；省略则全体启用成员按顺序发言。"))
                ]))
            ]))
        ])
    }

    private static func specSchema(
        includeTimeout: Bool,
        includeDisplayOptions: Bool
    ) -> JSONValue {
        var properties: [String: JSONValue] = [
            "topic": object([
                ("type", .string("string")),
                ("description", .string("讨论议题 / 要决策的问题。用 group 复用已保存讨论组时，这里可以覆盖该组的议题。"))
            ]),
            "name": object([
                ("type", .string("string")),
                ("description", .string("本次讨论的显示名，会落盘便于事后查。省略则自动生成。"))
            ]),
            "group": object([
                ("type", .string("string")),
                ("description", .string("复用已保存讨论组的名字（见 discussion_groups）。给了它就只需再给 topic。"))
            ]),
            "participants": object([
                ("type", .string("array")),
                ("items", participantSchema),
                ("description", .string("成员列表，至少 2 位。省略时用 group 里的成员。"))
            ]),
            "rounds": object([
                ("type", .string("array")),
                ("items", roundSchema),
                ("description", .string("议程。省略则用默认三步：独立论述 → 交叉质询 → 主席收敛。"))
            ]),
            "consensus": object([
                ("type", .string("string")),
                ("enum", .array([
                    .string("moderatorSummary"),
                    .string("majorityVote"),
                    .string("unanimous"),
                    .string("chairmanDecides")
                ])),
                ("description", .string("收敛方式。默认 moderatorSummary（主席汇总）。多数投票/一致同意会要求成员以 VOTE: YES/NO 收尾。"))
            ]),
            "moderator": object([
                ("type", .string("string")),
                ("description", .string("主席的成员名。省略则取第一位启用成员。"))
            ])
        ]

        if includeTimeout {
            properties["timeoutSeconds"] = object([
                ("type", .string("integer")),
                ("description", .string("阻塞等待上限（秒），默认 1800，最大 3600。超时不等于失败：任务仍在后台跑，改用 discussion_status 轮询。")),
                ("minimum", .int(30)),
                ("maximum", .int(3600))
            ])
        }

        if includeDisplayOptions {
            properties["maxCharsPerUtterance"] = object([
                ("type", .string("integer")),
                ("description", .string("返回文本里每条发言最多保留多少字符，默认 2000。")),
                ("minimum", .int(200))
            ])
        }

        return object([
            ("type", .string("object")),
            ("properties", .object(properties)),
            ("required", .emptyArray)
        ])
    }

    // MARK: - 小工具

    private static func object(_ pairs: [(String, JSONValue)]) -> JSONValue {
        .object(Dictionary(pairs, uniquingKeysWith: { first, _ in first }))
    }
}
