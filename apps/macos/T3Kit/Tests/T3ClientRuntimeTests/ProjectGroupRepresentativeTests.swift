import Testing
import T3Contracts
import T3Protocol
@testable import T3ClientRuntime

/// New threads start in a group's representative, so it must not be a disconnected environment when another has the project.
@Suite struct ProjectGroupRepresentativeTests {
  let dead = EnvironmentId("env-dead"), live = EnvironmentId("env-live")

  func groups(connected: Set<EnvironmentId>?, preferred: EnvironmentId? = nil) -> [ProjectGroup] {
    var shell = Data2.shell().projects[0]
    shell.workspaceRoot = "/work/app"
    shell.repositoryIdentity = RepositoryIdentity(canonicalKey: "github.com/acme/app", locator: RepositoryIdentityLocator(remoteName: "origin", remoteUrl: "git@github.com:acme/app.git"))
    let projects = [dead, live].map { EnvironmentProject(environmentId: $0, project: shell) }
    return ProjectGrouping.buildGroups(
      projects: projects, settings: ProjectGroupingSettings(mode: .repository), preferredEnvironmentId: preferred, connectedEnvironmentIds: connected)
  }

  @Test func aDisconnectedEnvironmentOnlyRepresentsAGroupNobodyElseHas() {
    #expect(groups(connected: nil).first?.representative.environmentId == dead)
    let both = groups(connected: [live])
    #expect(both.count == 1 && both[0].members.count == 2 && both[0].representative.environmentId == live)
    // A preferred environment that is down loses to a connected one; with nothing connected the preference still applies.
    #expect(groups(connected: [live], preferred: dead).first?.representative.environmentId == live)
    #expect(groups(connected: [], preferred: live).first?.representative.environmentId == live)
  }
}
