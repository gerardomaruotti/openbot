import Foundation

enum SampleConversations {
    static let all: [Conversation] = [
        Conversation(
            id: "luisa", name: "Travel", avatar: "luisa", preview: "Your sample itinerary is ready.", dateLabel: "25/03/2026",
            messages: [
                ChatMessage(id: "luisa-link", content: .link(title: "Example city guide", domain: "example.com"), timestamp: "Sat, 28 Feb at 7:10 PM"),
                ChatMessage(id: "luisa-pass", content: .attachment(name: "Example-ticket.pkpass", detail: "Pass · 16 KB"), isOutgoing: true, timestamp: "Tue, 17 Mar at 7:47 AM"),
                ChatMessage(id: "luisa-emoji", content: .emoji("😊"), isOutgoing: true),
                ChatMessage(id: "luisa-hearts", content: .text("❤️❤️❤️❤️")),
                ChatMessage(id: "luisa-theatre", content: .text("The sample museum visit starts at ten."), timestamp: "Wed, 25 Mar at 9:55 PM", showsTail: false),
                ChatMessage(id: "luisa-wow", content: .text("There is time for a walk afterwards.")),
                ChatMessage(id: "luisa-message", content: .text("Would you like to include a lunch stop in this example plan?"), timestamp: "Wed, 25 Mar at 11:54 PM", showsTail: false),
                ChatMessage(id: "luisa-alive", content: .text("Your sample itinerary is ready.")),
                ChatMessage(id: "luisa-pdf", content: .attachment(name: "Example-itinerary.pdf", detail: "PDF · 104 KB"), timestamp: "Sat, 28 Mar at 4:57 PM")
            ], isPinned: true
        ),
        Conversation(id: "mamma", name: "Daily Brief", avatar: "mamma", preview: "Your example briefing is ready.", dateLabel: "Yesterday", messages: [ChatMessage(id: "mamma-hello", content: .text("Your example briefing is ready."))], isPinned: true),
        Conversation(id: "francesco", name: "Research", avatar: "francesco", preview: "Here are three sample options.", dateLabel: "Yesterday", messages: [ChatMessage(id: "francesco-hello", content: .text("Here are three sample options."))], isPinned: true),
        Conversation(
            id: "instinct", name: "Atlas", avatar: "agent",
            preview: "Your sample plan is ready to review.", dateLabel: "30/10/2026",
            messages: [
                ChatMessage(id: "instinct-groups", content: .text("This example conversation shows a weekend plan. All names and messages are synthetic."), timestamp: "Fri, 30 Oct at 9:00 AM", showsTail: false),
                ChatMessage(id: "instinct-dinner", content: .text("For this sample dinner plan, compare a quiet cafe, a garden restaurant and a small neighbourhood bistro.")),
                ChatMessage(id: "instinct-stop", content: .text("Please keep the sample plan simple."), isOutgoing: true, receipt: "Read 30/10/2026"),
                ChatMessage(id: "instinct-final", content: .text("Your sample plan is ready to review."), reaction: .like)
            ]
        ),
        Conversation(id: "trenitalia", name: "Rail Updates", avatar: "agent", preview: "Your example journey is on schedule.", dateLabel: "07/10/2026", messages: [ChatMessage(id: "train-notice", content: .text("Your example journey is on schedule. This is a demo update."))]),
        Conversation(id: "myprotein", name: "Example Survey", avatar: "agent", preview: "Website: Example feedback survey (example.com)", dateLabel: "06/06/2026", messages: [ChatMessage(id: "survey", content: .link(title: "Website: Example feedback survey", domain: "example.com"))]),
        Conversation(id: "apple", name: "Order Updates", avatar: "agent", preview: "Example order DEMO-0001 is ready for collection.", dateLabel: "15/03/2026", messages: [ChatMessage(id: "apple-order", content: .text("Example order DEMO-0001 is ready for collection."))], isVerified: true),
        Conversation(id: "papa", name: "Home", avatar: "papa", preview: "The example shopping list is ready.", dateLabel: "07/02/2025", messages: [ChatMessage(id: "papa-notice", content: .text("The example shopping list is ready."))]),
        Conversation(id: "phone", name: "Demo Contact", avatar: "phone", preview: "Test", dateLabel: "8:28 AM", messages: [ChatMessage(id: "phone-test", content: .text("Test"), isOutgoing: true, timestamp: "Today 8:28 AM", receipt: "Read 8:28 AM")], isVisible: false)
    ]
}
