//
//  SummaryService.swift
//  Whisper
//
//  Created by Kirlos Yousef on 11/11/2025.
//

import Foundation
import SwiftData
import UIKit

public class SummaryService {
    // Private singleton instance
    private static let shared = SummaryService()
    private let apiKey: String
    private let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
    
    public enum ExportFormat {
        case markdown
        case text
    }
    
    // Model selection: Use the appropriate OpenAI chat model
    // Options: "gpt-4o-mini" (fast & cheap), "gpt-4o" (more capable), "gpt-3.5-turbo" (legacy)
    // As of 2024, gpt-4o-mini is recommended for simple tasks like summarization
    private let model = "gpt-4o-mini"
    
    private init() {
        // Load API key from Config.plist (same as TranscriptionService)
        if let path = Bundle.main.path(forResource: "Config", ofType: "plist"),
           let config = NSDictionary(contentsOfFile: path),
           let key = config["OpenAIAPIKey"] as? String, !key.isEmpty, key != "YOUR_API_KEY_HERE" {
            self.apiKey = key
        } else {
            self.apiKey = "YOUR_API_KEY_HERE"
        }
    }
    
    // MARK: - Translation
    public static func translate(text: String, to targetCode: String) async -> String {
        guard !text.isEmpty else { return "" }
        // If no API key or auto/no-op, return original text
        guard shared.apiKey != "YOUR_API_KEY_HERE",
              !targetCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              targetCode.lowercased() != "auto" else {
            return text
        }
        let targetLanguage = Languages.displayName(for: targetCode)
        do {
            var request = URLRequest(url: shared.endpoint)
            request.httpMethod = "POST"
            request.setValue("Bearer \(shared.apiKey)", forHTTPHeaderField: "Authorization")
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
            lines.append("\nTranscript:\n\(recording.fullTranscript)")
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
            md += "\n## Transcript\n\(recording.fullTranscript)\n"
            return md
        }
    }
    
    public static func generateSummary(for transcript: String) async -> (summary: String, todos: [String]) {
        // Use OpenAI API if key is configured
        if shared.apiKey != "YOUR_API_KEY_HERE" && !transcript.isEmpty {
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
        if shared.apiKey != "YOUR_API_KEY_HERE" && !transcript.isEmpty {
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
    
    // MARK: - Q&A
    public static func answerQuestion(transcript: String, question: String) async throws -> String {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ""
        }
        // If no API key, provide a minimal fallback
        guard shared.apiKey != "YOUR_API_KEY_HERE", !transcript.isEmpty else {
            return "Unable to answer without AI. Please configure OpenAI API key."
        }
        return try await shared.answerQuestionWithOpenAI(transcript: transcript, question: question)
    }
    
    // MARK: - General Command/Action
    public static func performCommand(transcript: String, command: String) async -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard shared.apiKey != "YOUR_API_KEY_HERE", !transcript.isEmpty else {
            return "Unable to process without AI. Please configure OpenAI API key."
        }
        do {
            return try await shared.performCommandWithOpenAI(transcript: transcript, command: trimmed)
        } catch {
            return "Failed to process: \(error.localizedDescription)"
        }
    }
    
    // MARK: - Keywords
    public static func extractKeywords(for transcript: String, maxKeywords: Int = 8) async -> [String] {
        guard shared.apiKey != "YOUR_API_KEY_HERE", !transcript.isEmpty else {
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
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30.0 // Add explicit timeout
        
        let prompt = """
        You are a precise assistant. Read the transcript and produce STRICT JSON with keys 'summary' (string) and 'todos' (array of strings). Do not include any extra keys or prose.\n\nTranscript:\n\n\(truncatedTranscript)
        """
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": "You are a helpful assistant that summarizes transcripts and extracts action items."],
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
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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
    func performCommandWithOpenAI(transcript: String, command: String) async throws -> String {
        let maxTranscriptLength = 6000
        let truncatedTranscript = transcript.count > maxTranscriptLength
            ? String(transcript.prefix(maxTranscriptLength)) + "..."
            : transcript
        
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30.0
        
        let system = """
        You operate on a conversation transcript. Perform the requested task (e.g., summarize, extract action items, extract keywords, translate, reformat, or answer questions) using ONLY the transcript. Respond concisely in plain text suitable for sharing. Avoid disclaimers.
        """
        let user = """
        Transcript:
        \(truncatedTranscript)
        
        Instruction:
        \(command)
        """
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ],
            "temperature": 0.3,
            "max_tokens": 600
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30.0
        config.timeoutIntervalForResource = 60.0
        let session = URLSession(configuration: config)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let responseBody = String(data: data, encoding: .utf8) ?? "Unable to decode response"
            throw NSError(domain: "SummaryService", code: 4, userInfo: [NSLocalizedDescriptionKey: "Command API error: \(responseBody)"])
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
        return content
    }
    func extractKeywordsWithOpenAI(transcript: String, maxKeywords: Int) async throws -> [String] {
        let maxTranscriptLength = 4000
        let truncatedTranscript = transcript.count > maxTranscriptLength
            ? String(transcript.prefix(maxTranscriptLength)) + "..."
            : transcript
        
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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
    func answerQuestionWithOpenAI(transcript: String, question: String) async throws -> String {
        // Limit transcript length to keep payload small
        let maxTranscriptLength = 6000
        let truncatedTranscript = transcript.count > maxTranscriptLength
            ? String(transcript.prefix(maxTranscriptLength)) + "..."
            : transcript
        
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30.0
        
        let system = """
        You answer questions strictly using the provided transcript. \
        If the answer is not clearly present, reply with: \"Not found in transcript.\" \
        Be concise (<= 2 sentences).
        """
        let user = """
        Transcript:
        \(truncatedTranscript)
        
        Question: \(question)
        """
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ],
            "temperature": 0.2,
            "max_tokens": 200
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30.0
        config.timeoutIntervalForResource = 60.0
        let session = URLSession(configuration: config)
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let responseBody = String(data: data, encoding: .utf8) ?? "Unable to decode response"
            throw NSError(domain: "SummaryService", code: 2, userInfo: [NSLocalizedDescriptionKey: "Q&A API error: \(responseBody)"])
        }
        
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
}

