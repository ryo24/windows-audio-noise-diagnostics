using System;
namespace AudioNoiseDiagnostics {
    public sealed class CaptureAddressChoice {
        public string Address, Label;
        public override string ToString(){return Address;}
    }
    public sealed class ReceiverNetworkEvent {
        public string Utc, Kind, Peer, Route, Reason, Browser, ConnectionId, Method, AttemptId;
        public int HttpStatus, BrowserMajor;
        public long HeaderBytes, BodyBytes, ExpectedBytes;
    }
    public sealed class ReceiverNetworkSnapshot {
        public string StartedUtc, LastOtherDeviceUtc, EndReason, LastError;
        public int TcpConnections, OtherDeviceConnections, HttpResponses, TlsConnections, ActiveConnections, ActiveUploads, AcceptedFiles;
        public long AcceptedBytes, ReservedUploadBytes;
        public bool Finished;
        public ReceiverNetworkEvent[] Events;
        public string Scope="TCP arrival is not proof that a phone page loaded. No client IP, URL, token, header, cookie or payload is stored here.";
    }
}
