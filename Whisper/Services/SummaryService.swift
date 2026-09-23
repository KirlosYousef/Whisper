//
//  SummaryService.swift
//  Whisper
//
//  Created by Kirlos Yousef on 11/11/2025.
//

import Foundation
import SwiftData
import UIKit

struct TranscriptConversationMessage: Sendable {
    enum Role: String, Sendable {
        case user
        case assistant
    }

    let role: Role
    let content: String
}

public class SummaryService {
    // Private singleton instance
    private static let shared = SummaryService()
    private let endpoint = OpenAIConfiguration.chatCompletionsURL
    
    public enum ExportFormat {
        case markdown
        case text
    }
    
    // Model selection: Use the appropriate OpenAI chat model
    // Options: "gpt-4o-mini" (fast & cheap), "gpt-4o" (more capable), "gpt-3.5-turbo" (legacy)
    // As of 2024, gpt-4o-mini is recommended for simple tasks like summarization
    private let model = "gpt-4o-mini"
    
    private init() {
    }
    
    // MARK: - Translation
    public static func translate(text: String, to targetCode: String) async -> String {
        guard !text.isEmpty else { return "" }
        // If the Worker is not configured or this is a no-op, return original text.
        guard OpenAIConfiguration.isConfigured,
              !targetCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              targetCode.lowercased() != "auto" else {
            return text
        }
        let targetLanguage = Languages.displayName(for: targetCode)
        do {
            var request = URLRequest(url: shared.endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 30.0
            
            let system = "You are a precise translator. Output ONLY the translated text. No extra notes."
            let user = "Translate the following text to \(targetLanguage). Return only the translated text:\n\n\(text)"
            let body: [String: Any] = [
                "model": shared.model,
                "messages": [
                    ["role": "system", "content": system],
                    ["role": "user", "content": user]
                ],
                "temperature": 0.2,
                "max_tokens": 4000
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30.0
            config.timeoutIntervalForResource = 60.0
            let session = URLSession(configuration: config)
            
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return text
            }
            struct OpenAIResponse: Decodable {
                struct Choice: Decodable {
                    struct Message: Decodable { let content: String }
                    let message: Message
                }
                let choices: [Choice]
            }
            let decoded = try JSONDecoder().decode(OpenAIResponse.self, from: data)
            let content = decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return content.isEmpty ? text : content
        } catch {
            return text
        }
    }
    
    // Public static methods
    static func shareRecording(_ recording: Recording) {
        let text = exportString(for: recording, format: .text)
        let activityVC = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first,
           let rootViewController = window.rootViewController {
            DispatchQueue.main.async {
                rootViewController.present(activityVC, animated: true)
                activityVC.completionWithItemsHandler = { _, completed, _, _ in
                    guard completed else { return }
                    Task { @MainActor in
                        LovePromptManager.shared.noteShareOrExport(delay: 0.6)
                    }
                }
            }
        }
    }
    
    static func shareRecording(_ recording: Recording, format: ExportFormat) {
        let exported = exportString(for: recording, format: format)
        let activityVC = UIActivityViewController(activityItems: [exported], applicationActivities: nil)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first,
           let rootViewController = window.rootViewController {
            DispatchQueue.main.async {
                rootViewController.present(activityVC, animated: true)
                activityVC.completionWithItemsHandler = { _, completed, _, _ in
                    guard completed else { return }
                    Task { @MainActor in
                        LovePromptManager.shared.noteShareOrExport(delay: 0.6)
                    }
                }
            }
        }
    }

    public static func exportString(for recording: Recording, format: ExportFormat) -> String {
        switch format {
        case .text:
            var lines: [String] = []
            let title = recording.title?.isEmpty == false ? recording.title! : "Recording"
            lines.append("\(title)")
            lines.append("Date: \(recording.createdAt.formatted())")
            lines.append("Duration: \(formatDuration(recording.duration))")
            if let keywords = recording.keywords, !keywords.isEmpty {
                lines.append("Keywords: \(keywords.joined(separator: ", "))")
            }
            if let summary = recording.summary, !summary.isEmpty {
                lines.append("\nSummary:\n\(summary)")
            }
            if let todos = recording.todoList, !todos.isEmpty {
                lines.append("\nAction Items:")
                lines.append(contentsOf: todos.map { "- \($0)" })
            }
            lines.append("\nTranscript:\n\(transcriptExportBody(for: recording, markdown: false))")
            return lines.joined(separator: "\n")
        case .markdown:
            let title = recording.title?.isEmpty == false ? recording.title! : "Recording"
            var md = "# \(title)\n\n"
            md += "- Date: \(recording.createdAt.formatted())\n"
            md += "- Duration: \(formatDuration(recording.duration))\n"
            if let keywords = recording.keywords, !keywords.isEmpty {
                md += "- Keywords: " + keywords.map { "`\($0)`" }.joined(separator: ", ") + "\n"
            }
            if let summary = recording.summary, !summary.isEmpty {
                md += "\n## Summary\n\(summary)\n"
            }
            if let todos = recording.todoList, !todos.isEmpty {
                md += "\n## Action Items\n"
                for t in todos { md += "- \(t)\n" }
            }
            md += "\n## Transcript\n\(transcriptExportBody(for: recording, markdown: true))\n"
            return md
        }
    }

    public static func transcriptExportBody(for recording: Recording, markdown: Bool) -> String {
        let segs = recording.sortedSegments.filter {
            $0.status == "completed" && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard segs.contains(where: { !($0.speakerKey?.isEmpty ?? true) }) else {
            return recording.fullTranscript
        }
        return segs.map { segment in
            let name = recording.displayName(for: segment.speakerKey ?? "")
            let start = segment.playbackStart
            let end = segment.playbackEnd > start ? segment.playbackEnd : recording.duration
            let range = SpeakerTimeFormatting.compactRange(start, end)
            if markdown {
                return "**\(name)** (\(range))\n\(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
            return "\(name) (\(range))\n\(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))"
        }.joined(separator: "\n\n")
    }
    
    public static func generateSummary(for transcript: String) async -> (summary: String, todos: [String]) {
        // Use OpenAI API if key is configured
        if OpenAIConfiguration.isConfigured && !transcript.isEmpty {
            do {
                let (summary, todos) = try await shared.summarizeWithOpenAI(transcript: transcript)
                return (summary, todos)
            } catch {
                print("SummaryService: OpenAI API failed, error: \(error)")
            }
        }
        // Fallback
        let summary = "This is a recorded conversation about \(transcript.prefix(50))..."
        let todos = ["Review the transcript", "Follow up on key points"]
        return (summary, todos)
    }
    
    public static func generateShortSummary(for transcript: String) async -> (summary: String, todos: [String]) {
        // Use OpenAI API if key is configured
        if OpenAIConfiguration.isConfigured && !transcript.isEmpty {
            do {
                let summary = try await shared.summarizeShortWithOpenAI(transcript: transcript)
                return (summary, [])
            } catch {
                print("SummaryService: OpenAI API failed, error: \(error)")
            }
        }
        // Fallback
        let summary = String(transcript.prefix(20))
        return (summary, [])
    }
    
    static func continueTranscriptConversation(
        transcript: String,
        history: [TranscriptConversationMessage],
        message: String
    ) async throws -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard OpenAIConfiguration.isConfigured, !transcript.isEmpty else {
            return "Unable to process without AI. Please configure the Worker URL."
        }
        return try await shared.continueTranscriptConversationWithOpenAI(
            transcript: transcript,
            history: history,
            message: trimmed
        )
    }

    static func suggestedConversationPrompts(
        transcript: String,
        history: [TranscriptConversationMessage],
        limit: Int = 3
    ) async -> [String] {
        guard OpenAIConfiguration.isConfigured, !transcript.isEmpty else { return [] }
        do {
            return try await shared.suggestedConversationPromptsWithOpenAI(
                transcript: transcript,
                history: history,
                limit: limit
            )
        } catch {
            return []
        }
    }
    
    // MARK: - Keywords
    public static func extractKeywords(for transcript: String, maxKeywords: Int = 8) async -> [String] {
        guard OpenAIConfiguration.isConfigured, !transcript.isEmpty else {
            return []
        }
        do {
            return try await shared.extractKeywordsWithOpenAI(transcript: transcript, maxKeywords: maxKeywords)
        } catch {
            print("SummaryService: Keyword extraction failed, error: \(error)")
            return []
        }
    }
    
    private func summarizeWithOpenAI(transcript: String) async throws -> (String, [String]) {
        // Limit transcript length to prevent oversized payloads (QUIC packet size issues)
        let maxTranscriptLength = 4000 // ~1000 tokens
        let truncatedTranscript = transcript.count > maxTranscriptLength 
            ? String(transcript.prefix(maxTranscriptLength)) + "..."
            : transcript
        
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30.0 // Add explicit timeout
        
        let prompt = """
        You are a precise assistant. Read the transcript and produce STRICT JSON with keys 'summary' (string) and 'todos' (array of strings). Do not include any extra keys or prose. If the transcript includes speaker labels or names, attribute statements to those speakers when relevant (for example, "Kirlos asked…").\n\nTranscript:\n\n\(truncatedTranscript)
        """
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": "You are a helpful assistant that summarizes transcripts and extracts action items. When speaker names or labels are present, mention who said or asked things when it improves the summary. Keep the JSON contract: keys 'summary' (string) and 'todos' (array of strings)."],
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.3,
            "max_tokens": 512,
            "response_format": ["type": "json_object"]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        // Configure URLSession with timeout
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30.0
        config.timeoutIntervalForResource = 60.0
        let session = URLSession(configuration: config)
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            print("❌ SummaryService: No HTTP response received")
            throw NSError(domain: "SummaryService", code: 1, userInfo: [NSLocalizedDescriptionKey: "No HTTP response"])
        }
        
        // Detailed error logging
        if httpResponse.statusCode != 200 {
            let responseBody = String(data: data, encoding: .utf8) ?? "Unable to decode response"
            print("❌ SummaryService: API Error")
            print("   Status Code: \(httpResponse.statusCode)")
            print("   Response: \(responseBody)")
            
            // Try to parse OpenAI error
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw NSError(domain: "SummaryService", code: httpResponse.statusCode, 
                            userInfo: [NSLocalizedDescriptionKey: "OpenAI API: \(message)"])
            }
            
            throw NSError(domain: "SummaryService", code: httpResponse.statusCode, 
                        userInfo: [NSLocalizedDescriptionKey: "OpenAI API error: HTTP \(httpResponse.statusCode)"])
        }
        
        print("✅ SummaryService: API request successful")
        // Parse OpenAI response
        struct OpenAIResponse: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable {
                    let content: String
                }
                let message: Message
            }
            let choices: [Choice]
        }
        let decoded = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        let content = decoded.choices.first?.message.content ?? ""
        // Try to parse JSON from the model's response
        if let jsonData = content.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
           let summary = json["summary"] as? String,
           let todos = json["todos"] as? [String] {
            return (summary, todos)
        } else {
            // Fallback: just return the content as summary, no todos
            return (content, [])
        }
    }
    
    private func summarizeShortWithOpenAI(transcript: String) async throws -> String {
        // Limit transcript length to prevent oversized payloads
        let maxTranscriptLength = 2000 // For short summaries, we need less context
        let truncatedTranscript = transcript.count > maxTranscriptLength 
            ? String(transcript.prefix(maxTranscriptLength)) + "..."
            : transcript
        
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30.0 // Add explicit timeout
        
        let prompt = "Summarize the following transcript in 2 or 3 words that best describe what it's about. Only return the 2 or 3 word summary, nothing else.\n\nTranscript:\n\n\(truncatedTranscript)"
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": "You are a helpful assistant that summarizes transcripts in 2 or 3 words."],
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.3,
            "max_tokens": 12
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        // Configure URLSession with timeout
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30.0
        config.timeoutIntervalForResource = 60.0
        let session = URLSession(configuration: config)
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            print("❌ SummaryService (Short): No HTTP response received")
            throw NSError(domain: "SummaryService", code: 1, userInfo: [NSLocalizedDescriptionKey: "No HTTP response"])
        }
        
        // Detailed error logging
        if httpResponse.statusCode != 200 {
            let responseBody = String(data: data, encoding: .utf8) ?? "Unable to decode response"
            print("❌ SummaryService (Short): API Error")
            print("   Status Code: \(httpResponse.statusCode)")
            print("   Response: \(responseBody)")
            
            // Try to parse OpenAI error
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw NSError(domain: "SummaryService", code: httpResponse.statusCode, 
                            userInfo: [NSLocalizedDescriptionKey: "OpenAI API: \(message)"])
            }
            
            throw NSError(domain: "SummaryService", code: httpResponse.statusCode, 
                        userInfo: [NSLocalizedDescriptionKey: "OpenAI API error: HTTP \(httpResponse.statusCode)"])
        }
        
        print("✅ SummaryService (Short): API request successful")
        struct OpenAIResponse: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable {
                    let content: String
                }
                let message: Message
            }
            let choices: [Choice]
        }
        let decoded = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        let content = decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return content
    }
    
    private static func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// MARK: - Private OpenAI helpers
private extension SummaryService {
    func continueTranscriptConversationWithOpenAI(
        transcript: String,
        history: [TranscriptConversationMessage],
        message: String
    ) async throws -> String {
        let maxTranscriptLength = 6000
        let truncatedTranscript = transcript.count > maxTranscriptLength
            ? String(transcript.prefix(maxTranscriptLength)) + "..."
            : transcript

        let system = """
        You are Revera's transcript assistant. Continue a natural conversation about the transcript below. \
        Answer questions and perform requested actions such as extracting action items, drafting follow-ups, \
        translating, summarizing, or reformatting. Use only information from the transcript. If information is \
        absent, say so clearly. Respect speaker names or labels. Be concise, useful, and conversational.

        Transcript:
        \(truncatedTranscript)
        """

        var messages: [[String: String]] = [["role": "system", "content": system]]
        messages.append(contentsOf: history.suffix(10).map {
            ["role": $0.role.rawValue, "content": $0.content]
        })
        messages.append(["role": "user", "content": message])

        return try await sendChatRequest(
            messages: messages,
            temperature: 0.3,
            maxTokens: 700,
            errorLabel: "Transcript conversation"
        )
    }

    func suggestedConversationPromptsWithOpenAI(
        transcript: String,
        history: [TranscriptConversationMessage],
        limit: Int
    ) async throws -> [String] {
        let maxTranscriptLength = 5000
        let truncatedTranscript = transcript.count > maxTranscriptLength
            ? String(transcript.prefix(maxTranscriptLength)) + "..."
            : transcript
        let historyText = history.suffix(6)
            .map { "\($0.role.rawValue): \($0.content)" }
            .joined(separator: "\n")
        let prompt = """
        Generate exactly \(limit) short, useful next prompts for this transcript conversation. \
        Make them specific to the transcript and diverse: include a question, an insight, or a useful action when appropriate. \
        If conversation history exists, suggest natural follow-ups without repeating previous requests. \
        Each prompt must be under 60 characters. Return strict JSON: {"suggestions":["..."]}.

        Transcript:
        \(truncatedTranscript)

        Conversation so far:
        \(historyText.isEmpty ? "None" : historyText)
        """
        let content = try await sendChatRequest(
            messages: [
                ["role": "system", "content": "You create concise, transcript-specific conversation starters and return strict JSON."],
                ["role": "user", "content": prompt]
            ],
            temperature: 0.45,
            maxTokens: 180,
            responseFormatJSON: true,
            errorLabel: "Prompt suggestions"
        )

        struct SuggestionResponse: Decodable { let suggestions: [String] }
        let cleaned = content
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = cleaned.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(SuggestionResponse.self, from: data) else {
            return []
        }
        return Array(decoded.suggestions
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(limit))
    }

    func sendChatRequest(
        messages: [[String: String]],
        temperature: Double,
        maxTokens: Int,
        responseFormatJSON: Bool = false,
        errorLabel: String
    ) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30.0

        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "temperature": temperature,
            "max_tokens": maxTokens
        ]
        if responseFormatJSON {
            body["response_format"] = ["type": "json_object"]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30.0
        config.timeoutIntervalForResource = 60.0
        let (data, response) = try await URLSession(configuration: config).data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let responseBody = String(data: data, encoding: .utf8) ?? "Unable to decode response"
            throw NSError(
                domain: "SummaryService",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "\(errorLabel) API error: \(responseBody)"]
            )
        }

        struct OpenAIResponse: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String }
                let message: Message
            }
            let choices: [Choice]
        }
        let decoded = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        return decoded.choices.first?.message.content
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    func extractKeywordsWithOpenAI(transcript: String, maxKeywords: Int) async throws -> [String] {
        let maxTranscriptLength = 4000
        let truncatedTranscript = transcript.count > maxTranscriptLength
            ? String(transcript.prefix(maxTranscriptLength)) + "..."
            : transcript
        
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30.0
        
        let prompt = """
        Extract up to \(maxKeywords) concise keywords or key phrases from the transcript. \
        Return STRICT JSON: {\"keywords\": [\"...\"]}. Use lowercase; no punctuation.
        Transcript:
        \(truncatedTranscript)
        """
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": "You extract keywords from transcripts and return strict JSON."],
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.2,
            "max_tokens": 128,
            "response_format": ["type": "json_object"]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let session = URLSession(configuration: .default)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let responseBody = String(data: data, encoding: .utf8) ?? "Unable to decode response"
            throw NSError(domain: "SummaryService", code: 3, userInfo: [NSLocalizedDescriptionKey: "Keyword API error: \(responseBody)"])
        }
        // Decode OpenAI chat response, then parse message.content JSON
        struct OpenAIResponse: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String }
                let message: Message
            }
            let choices: [Choice]
        }
        struct KeywordResponse: Decodable { let keywords: [String]? }
        let decoded = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        var content = decoded.choices.first?.message.content ?? ""
        // Defensive: strip code fences if any
        if content.hasPrefix("```") {
            content = content
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let jsonData = content.data(using: .utf8),
           let kw = try? JSONDecoder().decode(KeywordResponse.self, from: jsonData),
           let keywords = kw.keywords {
            return Array(keywords.prefix(maxKeywords))
        }
        // Last resort: attempt naive CSV split of the content
        let candidates = content
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        return Array(candidates.prefix(maxKeywords))
    }
}
