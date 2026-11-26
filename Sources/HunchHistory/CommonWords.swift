import Foundation

/// Lists of very common words that are too ordinary to be worth learning from casual use.
/// English: a single stopword, hand-listed, or frequent word is never a learning candidate (see
/// `isOrdinaryEnglish`); inside a qualifying phrase such words only earn a tenth of the credit
/// (`VocabularyScorer.commonFactor`). The Chinese list only damps credit.
///
/// A word written with a capital mid-sentence ("ask Mark", "in Swift") is a name and counts as
/// distinctive even when its lowercase form is ordinary; see `WordText.namesMidSentence`.
enum CommonWords {
    /// About 18,500 common English words with their inflections (generated from 12dicts, AGID and
    /// SCOWL; see `CommonWordsData.swift` and `scripts/make-common-words.py`).
    static let frequent: Set<String> = words(frequentEnglishText)

    /// Tech names that are also ordinary English words. They stay learnable when typed in lowercase
    /// ("built it in swift"). Stopwords still win.
    static let techNames: Set<String> = words("""
    swift react rust node slack spark flutter electron cargo dart notion rails
    """)

    /// Stopword, hand-listed common word, or frequent word, and not a tech name. Expects a
    /// lowercased English word.
    static func isOrdinaryEnglish(_ lowercased: String) -> Bool {
        if VocabularyScorer.enStopwords.contains(lowercased) { return true }
        if techNames.contains(lowercased) { return false }
        return english.contains(lowercased) || frequent.contains(lowercased)
    }

    static func isCommon(_ lowercased: String) -> Bool {
        english.contains(lowercased) || chinese.contains(lowercased)
    }

    private static func words(_ s: String) -> Set<String> {
        Set(s.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init))
    }

    static let english: Set<String> = words("""
    able accept access according account across act action active activity actually add address admit adult \
    advice afraid afternoon age agency agent ago agree agreed ahead air alive allow almost alone along \
    already although always amazing among amount and angry animal another answer anyone anything anyway \
    anywhere appear apply approach area argue arm army around arrive art article ask asked asking asleep \
    attack attention available average avoid away baby back bad bag ball bank bar base basic bath beach bear \
    beat beautiful become bed bedroom beer begin beginning behind believe bell belong best better beyond big \
    bill bird birth birthday bit black blood blue board boat body bone book born boring boss bottle bottom box \
    boy brain bread break breakfast bring brother brought brown build building burn business busy buy cake \
    call called calm came camera camp car card care careful carry case cat catch caught cause center century \
    certain chair chance change changed character charge cheap check child children choice choose church city \
    class clean clear clearly clever close clothes cloud club coffee cold college color colour come comes \
    coming common company complete computer condition consider contact continue control cook cool copy corner \
    cost count country couple course cover crazy create cross cry cup current customer cut dad daily dance \
    dark data date daughter day days dead deal dear death decide decided decision deep definitely degree \
    depend describe design detail develop dialog die difference different difficult dinner direction \
    directly discuss discussion dish distance doctor dog dollar done door doubt dream dress drink drive \
    driver drop dry due early earth easily east easy eat education effect effort eight either else email \
    empty end ended energy engine enjoy enough enter entire environment equal especially evening event ever \
    every everybody everyone everything exactly example excellent except excited exciting exist expect \
    expected experience explain express extra eye face fact fail fair fall family famous fan far farm fast \
    father fault favorite fear feel feeling feet fell felt few field fight figure fill film final finally \
    find fine finger finish fire firm first fish fit five fix floor fly follow following food foot force \
    foreign forget forgot form forward found four free french fresh friday friend friendly front fruit full \
    fun funny future game garden gave general gentle german get getting girl give given glad glass goal gold \
    gone good goodbye government great green ground group grow guess guest guy hair half hall hand handle \
    hang happen happened happy hard hate head health hear heard heart heat heavy held hello help helpful \
    herself high hill history hit hold holiday home hope horse hospital hot hotel hour house however huge \
    human hundred hurry hurt husband idea ill image imagine important impossible include including increase \
    indeed inside instead interest interested interesting internet interview introduce invite issue item job \
    join joke journey judge juice jump june july keep kept key kid kill kind king kitchen knew knock know \
    knowledge known lady lake land language large last late later laugh law lay lead learn least leave left \
    leg lend less lesson letter level library lie life light likely line list listen little live local long \
    look lose loss lost lot loud love low lucky lunch machine mail main major male man manage manager map \
    march mark market marry master match material matter maybe mean meaning meant measure meat media medical \
    meet meeting member mention message middle mile milk mind mine minute miss missed mistake mobile modern \
    moment monday money month moon morning mother mouth move movie music name nation national natural nature \
    near nearly necessary neck need needed neighbor never new news next nice night nine noise normal north \
    nose note nothing notice number nurse object obviously ocean offer office officer often oil old once open \
    opinion opportunity order ordinary original outside page pain paint pair paper parent park part particular \
    party pass past pay peace people perfect perhaps period person phone photo pick picture piece place plan \
    plane plant plastic play player please plenty pocket point police policy poor popular position possible \
    post pound power practice prepare present president press pretty price private prize probably problem \
    process produce product program project promise protect proud provide public pull purpose push put \
    quality quarter question quick quickly quiet quite race radio rain raise ran rate rather reach read \
    reading ready real reality realize reason receive recent recently record red refuse regular relation \
    remain remember remove repeat reply report require rest result return rich ride right ring rise river \
    road rock role room round rule run safe said sale salt sat saturday save saw scene school science screen \
    sea search season seat second secret section see seem seen sell send sense sent sentence serious serve \
    service set seven several shake shape share sharp sheep shirt shoe shop short shot shoulder show shown \
    shut sick side sign silly silver similar simple simply since sing single sister sit site situation six \
    size skin sky sleep slow slowly small smart smell smile smoke snow social soft solve somebody someone \
    something sometimes son song soon sorry sort sound soup south space speak special speed spend spoke sport \
    spring square staff stage stand star start state station stay step stick still stock stone stop store \
    storm story straight strange street strong student study stuff stupid subject succeed success sudden \
    suggest summer sun sunday support suppose sure surprise sweet swim system table tail talk tall taste \
    taught tea teach teacher team tell ten tend term terrible test thank thanks thick thin think third though \
    thought thousand three throw thursday ticket tie tight till time tip tired title today together told \
    tomorrow tonight took tooth top total touch toward town trade train travel tree trip trouble truck true \
    trust truth try tuesday turn twelve twenty twice two type uncle understand unit university unless unlikely \
    unusual usual usually vacation value various view village visit voice wait wake walk wall war warm wash \
    waste watch water wave way weak wear weather wednesday week weekend weight welcome west wet whatever \
    white whole wide wife wild win wind window wine winter wish within without woman women wonder wonderful \
    wood word work worker world worry worse worst worth write writer written wrong wrote yard year yellow \
    yesterday young youth zero zone \
    able across adding agreed alright answered anymore appreciate arrived asap attached based because \
    behalf bigger bring brought called cannot cheers chat check checked clarify click comment comments \
    complete confirm confirmed congrats consider contact content context copied correct could currently \
    deadline decided delay deliver delivered document documents download draft earlier effectively either \
    enable ensure everything exactly feedback figured finished follow forwarded further getting glad \
    handled happens helping hopefully hoping however important improve inform information instead involved \
    issues kindly later latest leaving letting looking lunch making meanwhile mentioned minutes moving \
    needs notes noticed okay online optional otherwise outline pending personally please possibly prefer \
    previous process provide providing question questions quickly reached read reason received receiving \
    regarding regards related remind reminder request requested resolve respond response review reviewed \
    schedule schedules sending sense setting share shared sharing should simply someone sorry started \
    starting status submit summary supposed sure thanks thing things thought through touch tried trying \
    update updated updates using wanted wondering working works would write yours \
    ages alarm album allowed apart apartment apple april august bake banana basket battery beach bike \
    bottle brush bucket butter button candle candy carpet cheese chicken chocolate cinema circle coast coin \
    cotton cream dentist desk dessert diary dirty dolphin drawer engineer fabric fence flower forest fork \
    garage gift ginger glove guitar hammer harbor hobby honey ice island jacket jelly jewel kettle ladder \
    lemon letter lion magazine mirror mountain mouse napkin needle notebook onion orange oven painting \
    pancake pasta pencil pepper piano pillow pizza plate pool potato pumpkin rabbit rice rocket salad \
    sandwich scarf sheet shelf shower sofa spoon stamp sugar suitcase sweater tennis toast tomato towel \
    toy umbrella vegetable wallet window yogurt \
    app apps wifi login logins logout username usernames password passwords smartphone smartphones \
    podcast podcasts upload uploads uploaded uploading timeline timelines emoji emojis selfie selfies \
    hashtag hashtags texting texted blogs blogging tweet tweets tweeted meme memes offline inbox signup \
    browser browsers screenshot screenshots chatbot smartwatch livestream bluetooth \
    gonna wanna gotta sorta yup haha lol btw omg thx pls fyi tbh idk \
    dont cant wont ive didnt doesnt isnt thats youre theres wasnt arent hasnt havent couldnt wouldnt \
    shouldnt
    """)

    /// Simplified script (traditional input is converted first). Taiwan words are listed in their own
    /// simplified form too (網路 → 网路), since script conversion doesn't map them to mainland words (网络).
    static let chinese: Set<String> = words("""
    今天 明天 昨天 早上 晚上 中午 下午 上午 时间 地方 东西 事情 问题 工作 学习 生活 朋友 家人 孩子 老师 学生 公司 \
    同事 电话 手机 电脑 网络 消息 信息 谢谢 对不起 不好 很多 一点 一下 一起 一直 一定 一些 当然 其实 真的 其他 别的 \
    开始 结束 喜欢 需要 希望 觉得 认为 看到 听到 想要 出来 进去 回来 过去 起来 下来 上去 下去 出去 这里 那里 哪里 \
    这么 那么 多少 几个 每天 每个 第一 第二 以前 以后 之前 之后 同时 马上 最近 刚才 一般 经常 有时 有点 特别 真是 \
    好的 可是 不过 只是 就要 只有 所有 大家 别人 别的 自己 我的 你的 他的 咱们 怎样 如何 为了 关于 对于 通过 根据 \
    吃饭 睡觉 上班 下班 回家 出门 见面 聊天 开会 休息 周末 星期 今年 明年 去年 月份 现在 目前 刚刚 已经 终于 突然 \
    网路 讯息 软体 程式 影片 资料 简讯 视讯 部落格 帐号 密码 档案 下载 上传 网站 网页 萤幕 设定 登入 回覆 留言 连结 \
    照片 资讯
    """)
}

/// Common English words for other modules (autocorrect keeps its one-slip candidates to these).
public enum CommonEnglish {
    /// Expects a lowercased word.
    public static func contains(_ lowercased: String) -> Bool { CommonWords.isOrdinaryEnglish(lowercased) }

    /// The everyday core: a stopword or a hand-listed common word ("the", "they", "from"), not just
    /// one of the ~18,500 frequent words ("thee", "arid"). Expects a lowercased word.
    public static func isEveryday(_ lowercased: String) -> Bool {
        VocabularyScorer.enStopwords.contains(lowercased) || CommonWords.english.contains(lowercased)
    }

    /// Words to search for a long garbled word (`FuzzyLexicon`): the common words (~18,500 with
    /// inflections). The spell checker's completions cover rarer words.
    public static func lexiconWords() -> [String] {
        Array(CommonWords.frequent.union(CommonWords.english))
    }
}
