import Foundation

enum AppLinks {
    static let repository = URL(string: "https://github.com/cyberpapiii/iMCP")!
    static let newIssue = repository.appendingPathComponent("issues/new")
    static let findMyPeopleSetupGuide = repository.appendingPathComponent("blob/main/docs/find-my-people-setup.md")
}
