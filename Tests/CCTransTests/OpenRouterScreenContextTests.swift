import CCTransCore
import Foundation
import Testing

@Suite(.serialized)
struct OpenRouterScreenContextTests {
    @Test func openRouterTextUsesSelectedVisionCapableTextModelWhenScreenContextIsProvided() async throws {
        let settings = TranslatorSettings(
            provider: .openRouter,
            openRouterTextModel: "minimax/minimax-m3",
            openRouterVisionModel: "openrouter/vision-model"
        )
        let service = TranslationService(session: stubbedOpenRouterSession { request in
            let body = try #require(request.jsonBody)
            #expect(body["model"] as? String == "minimax/minimax-m3")
            #expect(body["models"] == nil)

            let provider = try #require(body["provider"] as? [String: Any])
            let sort = try #require(provider["sort"] as? [String: Any])
            #expect(sort["by"] as? String == "throughput")
            #expect(sort["partition"] as? String == "none")

            let messages = try #require(body["messages"] as? [[String: Any]])
            let systemMessage = try #require(messages.first)
            let systemPrompt = try #require(systemMessage["content"] as? String)
            #expect(systemPrompt.contains("<translation_contract>"))
            #expect(systemPrompt.contains(#"<target_language_persona code="ko">"#))
            let userMessage = try #require(messages.last)
            let content = try #require(userMessage["content"] as? [[String: Any]])
            #expect(content.contains { $0["type"] as? String == "image_url" })
            let image = try #require(content.first { $0["type"] as? String == "image_url" })
            let imageURL = try #require(image["image_url"] as? [String: Any])
            #expect(imageURL["detail"] as? String == "low")
            let prompt = try #require(content.compactMap { $0["text"] as? String }.first)
            let promptData = try #require(prompt.data(using: .utf8))
            let payload = try #require(JSONSerialization.jsonObject(with: promptData) as? [String: Any])
            #expect(payload["selected_text"] as? String == "Translate this.")
            #expect(payload["target_language"] as? String == "Korean")

            let responseFormat = try #require(body["response_format"] as? [String: Any])
            let jsonSchema = try #require(responseFormat["json_schema"] as? [String: Any])
            let schema = try #require(jsonSchema["schema"] as? [String: Any])
            let properties = try #require(schema["properties"] as? [String: Any])
            #expect(properties.keys.contains("description"))

            return openRouterResponse("화면 컨텍스트 번역")
        })

        let result = try await service.translateText(
            "Translate this.",
            settings: settings,
            credentials: TranslatorCredentials(openRouterAPIKey: "test-key", huggingFaceToken: nil),
            contextImagePNGData: Data([0x89, 0x50, 0x4E, 0x47])
        )

        #expect(result.text == "화면 컨텍스트 번역")
        #expect(result.model == "minimax/minimax-m3")
        #expect(result.usage?.promptTokens == 11)
        #expect(result.usage?.completionTokens == 7)
        #expect(result.usage?.totalTokens == 18)
        #expect(result.usage?.costCredits == 0.000123)
    }

    @Test func openRouterTextParsesContextDescriptionSeparately() async throws {
        let settings = TranslatorSettings(
            provider: .openRouter,
            openRouterTextModel: "minimax/minimax-m3",
            openRouterVisionModel: "openrouter/vision-model"
        )
        let service = TranslationService(session: stubbedOpenRouterSession { request in
            let body = try #require(request.jsonBody)
            let messages = try #require(body["messages"] as? [[String: Any]])
            let systemMessage = try #require(messages.first)
            let prompt = try #require(systemMessage["content"] as? String)
            #expect(prompt.contains("Use standard forms such as 두 번."))
            #expect(prompt.contains("Omit recoverable subjects and pronouns"))
            #expect(!prompt.contains("translate the pronoun \"it\" literally as \"그것\""))
            return openRouterResponse(
                "그것",
                description: "이 문장에서 '그것'은 복사하려는 문장 전체를 의미합니다."
            )
        })

        let result = try await service.translateText(
            "it",
            settings: settings,
            credentials: TranslatorCredentials(openRouterAPIKey: "test-key", huggingFaceToken: nil),
            contextImagePNGData: Data([0x89, 0x50, 0x4E, 0x47])
        )

        #expect(result.text == "그것")
        #expect(result.description == "이 문장에서 '그것'은 복사하려는 문장 전체를 의미합니다.")
    }

    @Test func openRouterTextAppliesStyleOverlayWithoutChangingResponseContract() async throws {
        let settings = TranslatorSettings(
            provider: .openRouter,
            openRouterTextModel: "openrouter/text-model",
            sourceLanguage: "English",
            targetLanguage: "Korean"
        )
        let service = TranslationService(session: stubbedOpenRouterSession { request in
            let body = try #require(request.jsonBody)
            let messages = try #require(body["messages"] as? [[String: Any]])
            let systemMessage = try #require(messages.first)
            let prompt = try #require(systemMessage["content"] as? String)
            #expect(prompt.contains("Style applies only to the translation; keep description neutral."))
            let userMessage = try #require(messages.last)
            let request = try #require(userMessage["content"] as? String)
            let requestData = try #require(request.data(using: .utf8))
            let payload = try #require(JSONSerialization.jsonObject(with: requestData) as? [String: Any])
            #expect(payload["style_instructions"] as? [String] == ["Use a cheeky but non-insulting voice."])
            #expect(body["response_format"] != nil)
            return openRouterResponse("토큰 또 만료됐네.")
        })

        let result = try await service.translateText(
            "The token expired again.",
            settings: settings,
            credentials: TranslatorCredentials(openRouterAPIKey: "test-key", huggingFaceToken: nil),
            style: TranslationStyle(instructions: ["Use a cheeky but non-insulting voice."])
        )

        #expect(result.text == "토큰 또 만료됐네.")
    }

    @Test func openRouterTextRejectsKnownTextOnlyModelWhenScreenContextIsProvided() async throws {
        let settings = TranslatorSettings(
            provider: .openRouter,
            openRouterTextModel: "deepseek/deepseek-v4-flash"
        )
        let service = TranslationService(session: stubbedOpenRouterSession { _ in
            Issue.record("Text-only model should fail before sending an image request.")
            return Data()
        })

        await #expect(throws: TranslationError.unsupportedImageModel("deepseek/deepseek-v4-flash")) {
            try await service.translateText(
                "Translate this.",
                settings: settings,
                credentials: TranslatorCredentials(openRouterAPIKey: "test-key", huggingFaceToken: nil),
                contextImagePNGData: Data([0x89, 0x50, 0x4E, 0x47])
            )
        }
    }

    @Test func screenshotTranslationUsesDedicatedVisionModelEvenWhenTextModelIsDeepSeek() async throws {
        let settings = TranslatorSettings(
            provider: .openRouter,
            openRouterTextModel: "deepseek/deepseek-v4-flash",
            openRouterVisionModel: "google/gemini-3.1-flash-lite"
        )
        let service = TranslationService(session: stubbedOpenRouterSession { request in
            let body = try #require(request.jsonBody)
            #expect(body["model"] as? String == "google/gemini-3.1-flash-lite")
            #expect(body["models"] == nil)

            let messages = try #require(body["messages"] as? [[String: Any]])
            let systemMessage = try #require(messages.first)
            let systemPrompt = try #require(systemMessage["content"] as? String)
            #expect(systemPrompt.contains("Read and translate all visible human-readable text"))
            #expect(systemPrompt.contains(#"<target_language_persona code="ko">"#))
            let userMessage = try #require(messages.last)
            let content = try #require(userMessage["content"] as? [[String: Any]])
            #expect(content.contains { $0["type"] as? String == "image_url" })
            let request = try #require(content.compactMap { $0["text"] as? String }.first)
            let requestData = try #require(request.data(using: .utf8))
            let payload = try #require(JSONSerialization.jsonObject(with: requestData) as? [String: Any])
            #expect(payload["operation"] as? String == "translate_visible_text")
            #expect(payload["target_language"] as? String == "Korean")

            return openRouterResponse("선택 영역 번역")
        })

        let result = try await service.translateImage(
            pngData: Data([0x89, 0x50, 0x4E, 0x47]),
            settings: settings,
            credentials: TranslatorCredentials(openRouterAPIKey: "test-key", huggingFaceToken: nil)
        )

        #expect(result.text == "선택 영역 번역")
        #expect(result.model == "google/gemini-3.1-flash-lite")
    }

    @Test func screenshotTranslationUsesSelectedVisionCapableTranslationModelBeforeFallback() async throws {
        let settings = TranslatorSettings(
            provider: .openRouter,
            openRouterTextModel: "minimax/minimax-m3",
            openRouterVisionModel: "google/gemini-3.1-flash-lite"
        )
        let service = TranslationService(session: stubbedOpenRouterSession { request in
            let body = try #require(request.jsonBody)
            #expect(body["model"] as? String == "minimax/minimax-m3")
            #expect(body["modalities"] == nil)
            #expect(body["response_format"] != nil)

            let messages = try #require(body["messages"] as? [[String: Any]])
            let userMessage = try #require(messages.last)
            let content = try #require(userMessage["content"] as? [[String: Any]])
            #expect(content.contains { $0["type"] as? String == "image_url" })

            return openRouterResponse("선택 모델 번역")
        })

        let result = try await service.translateImage(
            pngData: Data([0x89, 0x50, 0x4E, 0x47]),
            settings: settings,
            credentials: TranslatorCredentials(openRouterAPIKey: "test-key", huggingFaceToken: nil)
        )

        #expect(result.text == "선택 모델 번역")
        #expect(result.model == "minimax/minimax-m3")
    }

    @Test func screenshotTranslationRequestsAndParsesImageOutputWhenTranslationModelCanGenerateImages() async throws {
        let settings = TranslatorSettings(
            provider: .openRouter,
            openRouterTextModel: "google/gemini-3.1-flash-image-preview",
            openRouterVisionModel: "google/gemini-3.1-flash-lite"
        )
        let imageURL = "data:image/png;base64,translated"
        let capabilities = OpenRouterModelCapabilities(
            inputModalities: ["text", "image"],
            outputModalities: ["image", "text"]
        )
        let service = TranslationService(
            session: stubbedOpenRouterSession { request in
                let body = try #require(request.jsonBody)
                #expect(body["model"] as? String == "google/gemini-3.1-flash-image-preview")
                #expect(body["response_format"] == nil)
                #expect(body["modalities"] as? [String] == ["image", "text"])

                let messages = try #require(body["messages"] as? [[String: Any]])
                let systemMessage = try #require(messages.first)
                let systemPrompt = try #require(systemMessage["content"] as? String)
                #expect(systemPrompt.contains("Return an edited version of the supplied screenshot"))
                #expect(systemPrompt.contains("Preserve layout, spacing, line wrapping, colors, icons, avatars, hierarchy, and app chrome"))
                #expect(systemPrompt.contains("Render exact Unicode text in a real UI font"))
                #expect(systemPrompt.contains("valid Unicode Hangul"))
                #expect(systemPrompt.contains("Apple SD Gothic Neo"))
                #expect(systemPrompt.contains("If only one output can be returned, return the edited image"))
                let userMessage = try #require(messages.last)
                let content = try #require(userMessage["content"] as? [[String: Any]])
                let request = try #require(content.compactMap { $0["text"] as? String }.first)
                let requestData = try #require(request.data(using: .utf8))
                let payload = try #require(JSONSerialization.jsonObject(with: requestData) as? [String: Any])
                #expect(payload["operation"] as? String == "translate_visible_text_and_edit_image")
                #expect(payload["target_language"] as? String == "Korean")
                #expect(content.contains { $0["type"] as? String == "image_url" })

                return openRouterImageResponse(content: "Slack 대화의 맥락상 OKR과 대시보드 운영 방식에 대한 후속 설명입니다.", imageURL: imageURL)
            },
            openRouterModelCapabilities: { modelID in
                modelID == "google/gemini-3.1-flash-image-preview" ? capabilities : nil
            }
        )

        // Image output is now the explicit upgrade path (.image), not the ⇧⌘2 default
        // (which is cheap vision/text). This exercises the "Translate as Image" upgrade.
        let result = try await service.translateImage(
            pngData: Data([0x89, 0x50, 0x4E, 0x47]),
            settings: settings,
            credentials: TranslatorCredentials(openRouterAPIKey: "test-key", huggingFaceToken: nil),
            mode: .image
        )

        #expect(result.text == "Slack 대화의 맥락상 OKR과 대시보드 운영 방식에 대한 후속 설명입니다.")
        #expect(result.imageURL == imageURL)
        #expect(result.model == "google/gemini-3.1-flash-image-preview")
    }

    // Design C: ⇧⌘2 defaults to cheap vision (text) even for an image-capable model. Edited
    // image output happens only on the explicit "Translate as Image" upgrade (mode: .image).
    @Test func screenshotDefaultsToVisionTextEvenWhenModelCanGenerateImages() async throws {
        let settings = TranslatorSettings(
            provider: .openRouter,
            openRouterTextModel: "google/gemini-3.1-flash-image-preview",
            openRouterVisionModel: "google/gemini-3.1-flash-lite"
        )
        let capabilities = OpenRouterModelCapabilities(
            inputModalities: ["text", "image"],
            outputModalities: ["image", "text"]
        )
        let service = TranslationService(
            session: stubbedOpenRouterSession { request in
                let body = try #require(request.jsonBody)
                // Vision path: structured text output, never image modalities.
                #expect(body["modalities"] == nil)
                #expect(body["response_format"] != nil)
                let messages = try #require(body["messages"] as? [[String: Any]])
                let systemPrompt = try #require(messages.first?["content"] as? String)
                #expect(systemPrompt.contains("Read and translate all visible human-readable text"))
                #expect(!systemPrompt.contains("Return an edited version of the supplied screenshot"))
                let content = try #require((messages.last?["content"]) as? [[String: Any]])
                let request = try #require(content.compactMap { $0["text"] as? String }.first)
                let requestData = try #require(request.data(using: .utf8))
                let payload = try #require(JSONSerialization.jsonObject(with: requestData) as? [String: Any])
                #expect(payload["operation"] as? String == "translate_visible_text")
                #expect(content.contains { $0["type"] as? String == "image_url" })
                return openRouterResponse("스크린샷 텍스트 번역")
            },
            openRouterModelCapabilities: { modelID in
                modelID == "google/gemini-3.1-flash-image-preview" ? capabilities : nil
            }
        )

        let result = try await service.translateImage(
            pngData: Data([0x89, 0x50, 0x4E, 0x47]),
            settings: settings,
            credentials: TranslatorCredentials(openRouterAPIKey: "test-key", huggingFaceToken: nil)
        )

        #expect(result.text == "스크린샷 텍스트 번역")
        #expect(result.imageURL == nil)
    }

    @Test func screenshotImageOutputRequestOmitsTemperatureAndClampsMaxTokensToCachedLimit() async throws {
        let settings = TranslatorSettings(
            provider: .openRouter,
            openRouterTextModel: "google/gemini-3.1-flash-image",
            openRouterVisionModel: "google/gemini-3.1-flash-lite"
        )
        let capabilities = OpenRouterModelCapabilities(
            inputModalities: ["text", "image"],
            outputModalities: ["image", "text"],
            maxCompletionTokens: 32_768,
            contextWindow: 131_072
        )
        let service = TranslationService(
            session: stubbedOpenRouterSession { request in
                let body = try #require(request.jsonBody)
                #expect(body["model"] as? String == "google/gemini-3.1-flash-image")
                // Regression guard for the HTTP 400 this reproduced: the old hardcoded
                // "gemini -> 65535" max_tokens overflowed this endpoint's combined
                // prompt+completion window, and the unconditional temperature broke
                // OpenAI image models. Both must be gone from the image-output request.
                #expect(body["max_tokens"] as? Int == 32_768)
                #expect(body["temperature"] == nil)

                return openRouterImageResponse(content: "번역됨", imageURL: "data:image/png;base64,x")
            },
            openRouterModelCapabilities: { modelID in
                modelID == "google/gemini-3.1-flash-image" ? capabilities : nil
            }
        )

        _ = try await service.translateImage(
            pngData: Data([0x89, 0x50, 0x4E, 0x47]),
            settings: settings,
            credentials: TranslatorCredentials(openRouterAPIKey: "test-key", huggingFaceToken: nil),
            mode: .image
        )
    }

    @Test func screenshotTranslationRejectsKnownTextOnlyVisionModel() async throws {
        let settings = TranslatorSettings(
            provider: .openRouter,
            openRouterVisionModel: "deepseek/deepseek-v4-flash"
        )
        let service = TranslationService(session: stubbedOpenRouterSession { _ in
            Issue.record("Text-only vision model should fail before sending an image request.")
            return Data()
        })

        await #expect(throws: TranslationError.unsupportedImageModel("deepseek/deepseek-v4-flash")) {
            try await service.translateImage(
                pngData: Data([0x89, 0x50, 0x4E, 0x47]),
                settings: settings,
                credentials: TranslatorCredentials(openRouterAPIKey: "test-key", huggingFaceToken: nil)
            )
        }
    }

    @Test func openRouterTextUsesTextModelWhenNoScreenContextExists() async throws {
        let settings = TranslatorSettings(
            provider: .openRouter,
            openRouterTextModel: "openrouter/text-model",
            openRouterVisionModel: "openrouter/vision-model"
        )
        let service = TranslationService(session: stubbedOpenRouterSession { request in
            let body = try #require(request.jsonBody)
            #expect(body["model"] as? String == "openrouter/text-model")

            let messages = try #require(body["messages"] as? [[String: Any]])
            let userMessage = try #require(messages.last)
            #expect(userMessage["content"] is String)

            return openRouterResponse("텍스트 번역")
        })

        let result = try await service.translateText(
            "Translate this.",
            settings: settings,
            credentials: TranslatorCredentials(openRouterAPIKey: "test-key", huggingFaceToken: nil)
        )

        #expect(result.text == "텍스트 번역")
        #expect(result.model == "openrouter/text-model")
    }

    @Test func openRouterTextPromptPreservesLineBreaks() async throws {
        let settings = TranslatorSettings(
            provider: .openRouter,
            openRouterTextModel: "openrouter/text-model"
        )
        let service = TranslationService(session: stubbedOpenRouterSession { request in
            let body = try #require(request.jsonBody)
            let messages = try #require(body["messages"] as? [[String: Any]])
            let systemMessage = try #require(messages.first)
            let systemPrompt = try #require(systemMessage["content"] as? String)
            #expect(!systemPrompt.contains("Return only"))
            #expect(systemPrompt.contains("Preserve meaning, facts, intent"))
            #expect(systemPrompt.contains("paragraph breaks, and line breaks"))
            let userMessage = try #require(messages.last)
            let request = try #require(userMessage["content"] as? String)
            let requestData = try #require(request.data(using: .utf8))
            let payload = try #require(JSONSerialization.jsonObject(with: requestData) as? [String: Any])
            #expect(payload["selected_text"] as? String == "first line\nsecond line")
            return openRouterResponse("첫 줄\n둘째 줄")
        })

        let result = try await service.translateText(
            "first line\nsecond line",
            settings: settings,
            credentials: TranslatorCredentials(openRouterAPIKey: "test-key", huggingFaceToken: nil)
        )

        #expect(result.text == "첫 줄\n둘째 줄")
    }

    @Test func openRouterTextStripsLeakedPromptInstructionFromStructuredResult() async throws {
        let settings = TranslatorSettings(
            provider: .openRouter,
            openRouterTextModel: "openrouter/text-model"
        )
        let service = TranslationService(session: stubbedOpenRouterSession { _ in
            openRouterResponse("""
            Note that you should only output the translated result without any additional explanation:

            Translation: 실제 번역
            """)
        })

        let result = try await service.translateText(
            "actual translation",
            settings: settings,
            credentials: TranslatorCredentials(openRouterAPIKey: "test-key", huggingFaceToken: nil)
        )

        #expect(result.text == "실제 번역")
    }

    @Test func openRouterTextStripsLeakedPromptInstructionFromPlainContentResult() async throws {
        let settings = TranslatorSettings(
            provider: .openRouter,
            openRouterTextModel: "openrouter/text-model"
        )
        let service = TranslationService(session: stubbedOpenRouterSession { _ in
            openRouterPlainContentResponse("""
            Only output the translated result without any additional explanation.

            Translated result: 일반 응답 번역
            """)
        })

        let result = try await service.translateText(
            "plain response translation",
            settings: settings,
            credentials: TranslatorCredentials(openRouterAPIKey: "test-key", huggingFaceToken: nil)
        )

        #expect(result.text == "일반 응답 번역")
    }

    @Test func openRouterTextStripsPromptWrapperLeaksAcrossSampleLengths() async throws {
        let samples: [(name: String, source: String, leaked: String, expected: String)] = [
            (
                name: "short",
                source: "REMETE",
                leaked: """
                <<<
                REMETE
                >>>

                번역:
                원격
                """,
                expected: "원격"
            ),
            (
                name: "medium",
                source: "The deployment failed because the database URL was missing.",
                leaked: """
                Text:
                <<<
                The deployment failed because the database URL was missing.
                >>>
                Translation: 데이터베이스 URL이 누락되어 배포가 실패했습니다.
                """,
                expected: "데이터베이스 URL이 누락되어 배포가 실패했습니다."
            ),
            (
                name: "long",
                source: """
                The new offline mode keeps a local cache of recent translations.
                Users can keep working while the network is unstable.
                Keep separate messages on separate lines.
                """,
                leaked: """
                <<<
                The new offline mode keeps a local cache of recent translations.
                Users can keep working while the network is unstable.
                Keep separate messages on separate lines.
                >>>

                번역 결과:
                새로운 오프라인 모드는 최근 번역의 로컬 캐시를 유지합니다.
                네트워크가 불안정한 동안에도 사용자는 계속 작업할 수 있습니다.
                별도의 메시지는 별도의 줄로 유지하세요.
                """,
                expected: """
                새로운 오프라인 모드는 최근 번역의 로컬 캐시를 유지합니다.
                네트워크가 불안정한 동안에도 사용자는 계속 작업할 수 있습니다.
                별도의 메시지는 별도의 줄로 유지하세요.
                """
            ),
        ]

        for sample in samples {
            let settings = TranslatorSettings(
                provider: .openRouter,
                openRouterTextModel: "openrouter/text-model"
            )
            let service = TranslationService(session: stubbedOpenRouterSession { _ in
                openRouterPlainContentResponse(sample.leaked)
            })

            let result = try await service.translateText(
                sample.source,
                settings: settings,
                credentials: TranslatorCredentials(openRouterAPIKey: "test-key", huggingFaceToken: nil)
            )

            #expect(result.text == sample.expected, "Failed cleanup sample: \(sample.name)")
            #expect(!result.text.contains("<<<"), "Failed cleanup sample: \(sample.name)")
            #expect(!result.text.contains(">>>"), "Failed cleanup sample: \(sample.name)")
            #expect(!result.text.contains("번역:"), "Failed cleanup sample: \(sample.name)")
        }
    }

    @Test func openRouterTextStreamsPlainTextWhenPartialHandlerProvided() async throws {
        let settings = TranslatorSettings(
            provider: .openRouter,
            openRouterTextModel: "openrouter/text-model"
        )
        let service = TranslationService(session: stubbedOpenRouterSession { request in
            let body = try #require(request.jsonBody)
            #expect(body["model"] as? String == "openrouter/text-model")
            #expect(body["stream"] as? Bool == true)
            #expect(body["response_format"] == nil)
            let streamOptions = try #require(body["stream_options"] as? [String: Any])
            #expect(streamOptions["include_usage"] as? Bool == true)

            let messages = try #require(body["messages"] as? [[String: Any]])
            let systemMessage = try #require(messages.first)
            let systemPrompt = try #require(systemMessage["content"] as? String)
            #expect(systemPrompt.contains("Return only the translated selected text"))
            let userMessage = try #require(messages.last)
            let request = try #require(userMessage["content"] as? String)
            let requestData = try #require(request.data(using: .utf8))
            let payload = try #require(JSONSerialization.jsonObject(with: requestData) as? [String: Any])
            #expect(payload["selected_text"] as? String == "Hello world")

            return openRouterStreamResponse(chunks: ["안녕", "하세요", " 세계"])
        })

        let partials = PartialCollector()
        let result = try await service.translateText(
            "Hello world",
            settings: settings,
            credentials: TranslatorCredentials(openRouterAPIKey: "test-key", huggingFaceToken: nil),
            onPartial: { partials.append($0) }
        )

        #expect(result.text == "안녕하세요 세계")
        #expect(result.usage?.totalTokens == 18)
        #expect(result.usage?.costCredits == 0.000123)
        let collected = partials.values
        #expect(!collected.isEmpty)
        #expect(collected.last == "안녕하세요 세계")
    }

    @Test func openRouterTextStreamPartialsStripLeakedPromptInstruction() async throws {
        let settings = TranslatorSettings(
            provider: .openRouter,
            openRouterTextModel: "openrouter/text-model"
        )
        let service = TranslationService(session: stubbedOpenRouterSession { _ in
            openRouterStreamResponse(chunks: [
                "Note that you should only output the translated result without any additional explanation:",
                "\n\n안녕하세요",
            ])
        })

        let partials = PartialCollector()
        let result = try await service.translateText(
            "Hello",
            settings: settings,
            credentials: TranslatorCredentials(openRouterAPIKey: "test-key", huggingFaceToken: nil),
            onPartial: { partials.append($0) }
        )

        #expect(result.text == "안녕하세요")
        #expect(partials.values.allSatisfy { !$0.contains("additional explanation") })
        #expect(partials.values.last == "안녕하세요")
    }
}

private func stubbedOpenRouterSession(
    handler: @escaping @Sendable (URLRequest) throws -> Data
) -> URLSession {
    OpenRouterStubURLProtocol.handler = handler
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [OpenRouterStubURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func openRouterResponse(_ translation: String, description: String? = nil) -> Data {
    let contentObject: [String: Any] = [
        "translation": translation,
        "description": description ?? NSNull(),
    ]
    let contentData = try! JSONSerialization.data(withJSONObject: contentObject)
    let content = String(data: contentData, encoding: .utf8)!
    let payload: [String: Any] = [
        "choices": [
            [
                "message": [
                    "content": content,
                ],
            ],
        ],
        "usage": [
            "prompt_tokens": 11,
            "completion_tokens": 7,
            "total_tokens": 18,
            "cost": 0.000123,
        ],
    ]
    return try! JSONSerialization.data(withJSONObject: payload)
}

private func openRouterPlainContentResponse(_ content: String) -> Data {
    let payload: [String: Any] = [
        "choices": [
            [
                "message": [
                    "content": content,
                ],
            ],
        ],
        "usage": [
            "prompt_tokens": 11,
            "completion_tokens": 7,
            "total_tokens": 18,
            "cost": 0.000123,
        ],
    ]
    return try! JSONSerialization.data(withJSONObject: payload)
}

private func openRouterImageResponse(content: String?, imageURL: String) -> Data {
    let messageContent: Any = content.map { $0 as Any } ?? NSNull()
    let payload: [String: Any] = [
        "choices": [
            [
                "message": [
                    "content": messageContent,
                    "images": [
                        [
                            "imageUrl": [
                                "url": imageURL,
                            ],
                        ],
                    ],
                ],
            ],
        ],
        "usage": [
            "prompt_tokens": 11,
            "completion_tokens": 7,
            "total_tokens": 18,
            "cost": 0.000123,
        ],
    ]
    return try! JSONSerialization.data(withJSONObject: payload)
}

private func openRouterStreamResponse(chunks: [String]) -> Data {
    var lines: [String] = []
    for chunk in chunks {
        let object: [String: Any] = ["choices": [["delta": ["content": chunk]]]]
        let data = try! JSONSerialization.data(withJSONObject: object)
        lines.append("data: \(String(data: data, encoding: .utf8)!)")
    }
    let usageObject: [String: Any] = [
        "choices": [],
        "usage": [
            "prompt_tokens": 11,
            "completion_tokens": 7,
            "total_tokens": 18,
            "cost": 0.000123,
        ],
    ]
    let usageData = try! JSONSerialization.data(withJSONObject: usageObject)
    lines.append("data: \(String(data: usageData, encoding: .utf8)!)")
    lines.append("data: [DONE]")
    return Data((lines.joined(separator: "\n") + "\n").utf8)
}

private final class PartialCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class OpenRouterStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> Data)?

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "openrouter.ai"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            let data = try Self.handler?(request) ?? Data()
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private extension URLRequest {
    var jsonBody: [String: Any]? {
        let bodyData: Data?
        if let httpBody {
            bodyData = httpBody
        } else if let httpBodyStream {
            httpBodyStream.open()
            defer {
                httpBodyStream.close()
            }

            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while httpBodyStream.hasBytesAvailable {
                let count = httpBodyStream.read(&buffer, maxLength: buffer.count)
                if count <= 0 {
                    break
                }
                data.append(buffer, count: count)
            }
            bodyData = data
        } else {
            bodyData = nil
        }

        guard let bodyData else {
            return nil
        }

        return (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any]
    }
}
