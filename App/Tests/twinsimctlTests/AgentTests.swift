import XCTest
@testable import twinsimctl
import TwinSimAgentProtocol

final class AgentTests: XCTestCase {
    func testScreenSpaceRoundTrip() {
        let space = ScreenSpace(guest: CGSize(width: 1080, height: 2400), maxEdge: 1280)
        XCTAssertEqual(space.imageSize, CGSize(width: 576, height: 1280))
        let (x, y) = space.toGuest(288, 640)
        XCTAssertEqual(x, 540); XCTAssertEqual(y, 1200)
        XCTAssertEqual(space.toGuest(10_000, -5).0, 1079)
        XCTAssertEqual(ScreenSpace(guest: CGSize(width: 720, height: 1280), maxEdge: 1280).scale, 1)
    }

    func testUITreeParsing() {
        let xml = """
        UI hierchary dumped to: /dev/tty<?xml version='1.0' encoding='UTF-8' standalone='yes' ?><hierarchy rotation="0">\
        <node index="0" text="" resource-id="" class="android.widget.FrameLayout" package="org.x" content-desc="" clickable="false" enabled="true" focused="false" scrollable="false" checked="false" bounds="[0,0][1080,2400]">\
        <node index="0" text="登录" resource-id="org.x:id/login" class="android.widget.Button" package="org.x" content-desc="" clickable="true" enabled="true" focused="false" scrollable="false" checked="false" bounds="[100,200][300,260]" />\
        </node></hierarchy>
        """
        let nodes = UITreeParser.parse(xml)
        XCTAssertEqual(nodes.count, 2)
        XCTAssertEqual(nodes[1].text, "登录")
        XCTAssertEqual(nodes[1].shortId, "login")
        XCTAssertEqual(nodes[1].center, CGPoint(x: 200, y: 230))
        XCTAssertFalse(nodes[0].interesting)
        let agent = Agent(maxEdge: 0)
        XCTAssertEqual(agent.match(nodes, text: "登录", resourceId: nil, desc: nil).first?.index, 1)
        XCTAssertEqual(agent.match(nodes, text: nil, resourceId: "login", desc: nil).count, 1)
    }

    func testSocketPathFallsBackWhenTooLong() {
        let long = "/" + String(repeating: "x", count: 120)
        let path = AgentProtocol.socketPath(environment: ["TWINSIM_HOME": long])
        XCTAssertLessThan(path.utf8.count, 104)
        XCTAssertEqual(AgentProtocol.socketPath(environment: ["TWINSIM_HOME": "/tmp/a"]), "/tmp/a/agent.sock")
    }

    func testToolSchemasAreValid() {
        let agent = Agent(maxEdge: 0)
        XCTAssertGreaterThan(agent.tools.count, 20)
        XCTAssertEqual(Set(agent.tools.map(\.name)).count, agent.tools.count)
        for tool in agent.tools {
            XCTAssertTrue(JSONSerialization.isValidJSONObject(tool.inputSchema), tool.name)
            for key in tool.required { XCTAssertNotNil(tool.properties[key], "\(tool.name).\(key)") }
            XCTAssertLessThanOrEqual(tool.name.count, 64)
        }
    }
}
