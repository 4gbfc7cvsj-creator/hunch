import Testing
@testable import HunchText

private let classifier = DefaultAIVoiceClassifier()

private struct Case: Sendable, CustomTestStringConvertible {
    let before: String
    let completion: String
    var testDescription: String { "\(before)|\(completion)" }
}

private let aiVoiceCases: [Case] = [
    Case(before: "I am a", completion: " bot."),
    Case(before: "I am a", completion: " bot"),
    Case(before: "I am a", completion: "n AI."),
    Case(before: "I'm an", completion: " AI assistant here to help"),
    Case(before: "I am just a", completion: " language model"),
    Case(before: "I am a", completion: " helpful assistant."),
    Case(before: "I am a", completion: " virtual assistant"),
    Case(before: "I am a", completion: " chatbot created by"),
    Case(before: "I am a", completion: " large language model trained"),
    Case(before: "Hello! I'm", completion: " an AI, so I"),
    Case(before: "Thanks for asking.", completion: " As an AI, I don't"),
    Case(before: "I", completion: " am an artificial intelligence"),
    Case(before: "I am an", completion: " assistant."),
    Case(before: "I'm a", completion: " A.I. that"),
    Case(before: "Write me a story about the sea.", completion: " Sure, here is"),
    Case(before: "", completion: "Certainly! Here"),
    Case(before: "Can you summarize this article?", completion: " Here's a summary"),
    Case(before: "Explain recursion.", completion: " Of course, recursion"),
    Case(before: "What is the capital of Peru?", completion: " I'm sorry, but"),
    Case(before: "Draft the memo.", completion: " I cannot help with"),
    Case(before: "Draft the memo. I", completion: " can't help with that"),
    Case(before: "The sky is blue", completion: " and the user wants"),
    Case(before: "Our trip was great", completion: ", here is a continuation"),
    Case(before: "我是", completion: "一个人工智能"),
    Case(before: "作为", completion: "一个AI，我"),
    Case(before: "我是", completion: "AI助手"),
    Case(before: "我是", completion: "语言模型。"),
    Case(before: "你好，我是", completion: "一个由谷歌开发的语言模型"),
    Case(before: "Nice to meet you! I'm an", completion: " open weights model, developed by Google DeepMind."),
    Case(before: "I am an", completion: " open-weights model"),
    Case(before: "I'm an", completion: " open source language model that"),
    Case(before: "Hello! I'm Gemma,", completion: " an open weights model"),
    Case(before: "Hi, I'm", completion: " Gemma, developed by Google DeepMind"),
    Case(before: "My name is", completion: " Gemini, a large language model"),
    Case(before: "Nice to meet you. I'm Sam,", completion: " a large language model trained by Google."),
    Case(before: "I was", completion: " developed by Google DeepMind."),
    Case(before: "I was", completion: " trained by OpenAI to help"),
    Case(before: "I'm", completion: " developed by Google"),
    Case(before: "你好！我是", completion: "一个开放权重模型"),
    Case(before: "你好！我是", completion: "一個開放權重模型，由Google DeepMind開發"),
    Case(before: "我是", completion: "由Google DeepMind开发的开放权重模型"),
    Case(before: "我是", completion: "由Google DeepMind開發的開放權重模型。"),
    Case(before: "你好，我是", completion: "Gemma，一個由Google開發的開放權重模型"),
    Case(before: "你好，我叫", completion: "Gemini，是一款大型語言模型"),
]

private let humanCases: [Case] = [
    Case(before: "I am a", completion: " student at UCLA"),
    Case(before: "I am a", completion: " software engineer working on AI"),
    Case(before: "I am a", completion: " bot developer at a startup"),
    Case(before: "I am an", completion: " AI researcher at Stanford"),
    Case(before: "I'm a", completion: " research assistant in the lab"),
    Case(before: "I am an", completion: " assistant professor of history"),
    Case(before: "I am a", completion: " model citizen"),
    Case(before: "I am a", completion: " large person"),
    Case(before: "We deployed", completion: " the bot we built last year"),
    Case(before: "As AI", completion: " becomes more capable, we"),
    Case(before: "Our chatbot answers questions. Sure", completion: " enough, it"),
    Case(before: "The assistant we hired is great. Here", completion: " is the plan"),
    Case(before: "Hi Sarah, thanks for the update on the project.", completion: " Sure, I can"),
    Case(before: "Hi Sarah, thanks for the update on the project. I", completion: "'m sorry for the delay"),
    Case(before: "Hi Sarah, thanks for the update on the project. I", completion: " will review it"),
    Case(before: "We talked about", completion: " surely the best option"),
    Case(before: "When the user clicks Save,", completion: " the user sees a dialog"),
    Case(before: "I am not a", completion: " robot vacuum fan"),
    Case(before: "I'm reading about", completion: " assistants at work"),
    Case(before: "我是", completion: "一名大学生"),
    Case(before: "我是", completion: "人工智能专业的学生"),
    Case(before: "作为一个AI", completion: "工程师，我每天"),
    Case(before: "今天天气很好，我们", completion: "去公园散步吧"),
    Case(before: "I am a", completion: ""),
    Case(before: "Our team shipped a model developed by", completion: " the data group last quarter"),
    Case(before: "I was trained by", completion: " my manager to run the weekly report"),
    Case(before: "I was developed by", completion: " nobody, I grew up on a farm"),
    Case(before: "I'm an open", completion: " source contributor to the project"),
    Case(before: "I'm an open", completion: " book exam kind of person"),
    Case(before: "I'm a", completion: " weight lifting coach"),
    Case(before: "Hi, I'm Gemma,", completion: " a nurse at the city hospital"),
    Case(before: "Hi, I'm Sam,", completion: " a language model researcher at MIT"),
    Case(before: "Hi, I'm", completion: " Gemma and I'll be your server"),
    Case(before: "My name is Gemma and I am a", completion: " teacher"),
    Case(before: "The report was developed by", completion: " Google DeepMind researchers in 2024"),
    Case(before: "你好，我是", completion: "開放大學的學生"),
    Case(before: "我是", completion: "一個開源軟體的維護者"),
    Case(before: "你好，我叫", completion: "Gemma，是一名護士"),
    Case(before: "我們團隊使用的是", completion: "由Google開發的開放權重模型"),
]

@Test(arguments: aiVoiceCases)
private func flagsAIVoice(_ c: Case) {
    #expect(classifier.isAIVoice(before: c.before, completion: c.completion))
}

@Test(arguments: humanCases)
private func keepsHumanText(_ c: Case) {
    #expect(!classifier.isAIVoice(before: c.before, completion: c.completion))
}

@Test func verdictKinds() {
    #expect(classifier.verdict(before: "I am a", completion: " bot.") == .selfIdentification)
    #expect(classifier.verdict(before: "Write a haiku.", completion: " Sure! Here") == .chatReply)
    #expect(classifier.verdict(before: "Our weekend", completion: " continuation of the user") == .metaTalk)
}

@Test func beforeDiscussingAIOnlyFlagsSelfIdentification() {
    let before = "We are building a chatbot for support tickets."
    #expect(!classifier.isAIVoice(before: before, completion: " Here is the plan"))
    #expect(classifier.isAIVoice(before: before + " I am a", completion: " bot."))
}

@Test func patternAlreadyInBeforeIsNotFlagged() {
    // The writer typed it themselves (e.g. fiction); the completion adds nothing AI-ish.
    #expect(!classifier.isAIVoice(before: "In the story, I am a bot", completion: " living in Paris"))
}
