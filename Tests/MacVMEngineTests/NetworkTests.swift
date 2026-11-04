import Foundation
@testable import MacVMEngine
import Testing

struct DHCPLeasesTests {
    let sample = """
    {
    	name=old
    	ip_address=192.168.64.2
    	hw_address=1,2:0:0:a:b:c
    	lease=0x60000000
    }
    {
    	name=new
    	ip_address=192.168.64.9
    	hw_address=1,2:0:0:a:b:c
    	lease=0x70000000
    }
    {
    	name=other
    	ip_address=192.168.64.3
    	hw_address=1,2:0:0:a:b:d
    	lease=0x70000000
    }
    """

    @Test func picksNewestLeaseForPaddedMAC() {
        #expect(DHCPLeases.ipAddress(forMAC: "02:00:00:0a:0b:0c", in: sample) == "192.168.64.9")
    }

    @Test func fallsBackToHostnameForDUIDClients() {
        let duid = sample + """

        {
        	name=deb
        	ip_address=192.168.64.20
        	hw_address=ff,f1:f5:dd:7f:0:2:0:0:ab:11
        	lease=0x70000000
        }
        """
        let beforeExpiry = Date(timeIntervalSince1970: 0x6FFF_FFFF)
        #expect(DHCPLeases.ipAddress(forMAC: "02:00:00:0a:0b:0f", hostname: "deb", in: duid, now: beforeExpiry) == "192.168.64.20")
        #expect(DHCPLeases.ipAddress(forMAC: "02:00:00:0a:0b:0f", hostname: "deb", in: duid, now: Date(timeIntervalSince1970: 0x7000_0001)) == nil)
        #expect(DHCPLeases.ipAddress(forMAC: "02:00:00:0a:0b:0f", in: duid) == nil)
    }

    @Test func unknownMAC() {
        #expect(DHCPLeases.ipAddress(forMAC: "02:00:00:0a:0b:0e", in: sample) == nil)
    }
}
