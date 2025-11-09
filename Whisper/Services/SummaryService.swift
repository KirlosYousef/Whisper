import Foundation
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

public class SummaryService {
    // Private singleton instance
    private static let shared = SummaryService()
    private let apiKey: String
    private let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
    
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
    
    // Public static methods
    #if canImport(UIKit)
    static func shareRecording(_ recording: Recording) {
        let text = """
        Recording from \(recording.createdAt.formatted())
        Duration: \(formatDuration(recording.duration))
        
        Transcript:
        \(recording.fullTranscript)
        
        \(recording.summary != nil ? "\nSummary:\n\(recording.summary!)" : "")
        \(recording.todoList != nil && !recording.todoList!.isEmpty ? "\n\nTodo Items:\n" + recording.todoList!.map { "- \($0)" }.joined(separator: "\n") : "")
        """
        
        let activityVC = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first,
           let rootViewController = window.rootViewController {
            DispatchQueue.main.async {
                rootViewController.present(activityVC, animated: true)
            }
        }
    }
    #endif
    
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
