using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Net.NetworkInformation;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace AudioNoiseDiagnostics {
    public class ReceivedMedia {
        public string Id, RelativePath, Sha256, MimeType, Kind, ReceivedUtc, ClientSentUtc, CaptureStartedUtc, CaptureEndedUtc, Note, Source, HeardNoise;
        public long Bytes; public bool PreviewConfirmed;
    }
    public sealed class LocalReceiver : IDisposable {
        public const long MaxFileBytes=134217728;
        readonly TcpListener listener; readonly string directory,webRoot,prefix,origin; readonly Thread thread;
        readonly Stopwatch lifetime=Stopwatch.StartNew(); readonly int lifetimeSeconds;
        readonly object gate=new object(); readonly HashSet<TcpClient> clients=new HashSet<TcpClient>();
        readonly HashSet<string> localAddresses=new HashSet<string>(); readonly ManualResetEventSlim drained=new ManualResetEventSlim(true);
        readonly ConcurrentQueue<ReceiverNetworkEvent> networkEvents=new ConcurrentQueue<ReceiverNetworkEvent>();
        volatile bool stop,listenerStopped; int tcpConnections,otherConnections,httpResponses,tlsConnections,inFlightUploads;long reservedBytes;
        readonly string startedUtc=DateTime.UtcNow.ToString("o"); string lastOtherUtc,endReason;
        public readonly ConcurrentQueue<ReceivedMedia> Received=new ConcurrentQueue<ReceivedMedia>();
        public readonly string Url,Address; public volatile bool Finished; public volatile int AcceptedCount; public long TotalBytes;
        public string LastError; public int Port {get;private set;}
        sealed class Context {public string Peer,Route="Unparsed",Browser="Unknown",ConnectionId=Guid.NewGuid().ToString("N"),Method="Unknown",AttemptId;public int BrowserMajor;public long HeaderBytes,BodyBytes,ExpectedBytes;}
        public static bool IsLocalAddress(string address) {
            IPAddress ip;if(!IPAddress.TryParse(address,out ip)||ip.AddressFamily!=AddressFamily.InterNetwork)return false;
            var b=ip.GetAddressBytes();return b[0]==127||b[0]==10||(b[0]==192&&b[1]==168)||(b[0]==172&&b[1]>=16&&b[1]<=31);
        }
        public static LocalReceiver Start(string address,string directory,string webRoot,int lifetimeSeconds) {return new LocalReceiver(address,directory,webRoot,lifetimeSeconds);}
        LocalReceiver(string address,string directory,string webRoot,int seconds) {
            if(!IsLocalAddress(address))throw new ArgumentException("Choose a private IPv4 address or loopback.");
            if(seconds<1||seconds>900)throw new ArgumentOutOfRangeException("seconds");
            this.directory=Path.GetFullPath(directory);this.webRoot=Path.GetFullPath(webRoot);lifetimeSeconds=seconds;Address=address;
            localAddresses.Add(address);foreach(var nic in NetworkInterface.GetAllNetworkInterfaces()){try{foreach(var ip in nic.GetIPProperties().UnicastAddresses)localAddresses.Add(ip.Address.ToString());}catch{}}
            var random=new byte[24];using(var rng=RandomNumberGenerator.Create()){rng.GetBytes(random);}
            string token=Convert.ToBase64String(random).TrimEnd('=').Replace('+','-').Replace('/','_');prefix="/s/"+token+"/";
            listener=new TcpListener(IPAddress.Parse(address),0);listener.Start(16);Port=((IPEndPoint)listener.LocalEndpoint).Port;
            origin="http://"+address+":"+Port;Url=origin+prefix;
            thread=new Thread(Run);thread.IsBackground=true;thread.Start();
        }
        void Record(Context context,string kind,int status,string reason) {
            networkEvents.Enqueue(new ReceiverNetworkEvent{Utc=DateTime.UtcNow.ToString("o"),Kind=kind,Peer=context==null?"Receiver":context.Peer,Route=context==null?"None":context.Route,HttpStatus=status,Reason=reason,Browser=context==null?"Unknown":context.Browser,BrowserMajor=context==null?0:context.BrowserMajor,ConnectionId=context==null?null:context.ConnectionId,Method=context==null?"Unknown":context.Method,AttemptId=context==null?null:context.AttemptId,HeaderBytes=context==null?0:context.HeaderBytes,BodyBytes=context==null?0:context.BodyBytes,ExpectedBytes=context==null?0:context.ExpectedBytes});
            ReceiverNetworkEvent ignored;while(networkEvents.Count>200)networkEvents.TryDequeue(out ignored);
        }
        public ReceiverNetworkSnapshot NetworkSnapshot() {
            lock(gate){return new ReceiverNetworkSnapshot{StartedUtc=startedUtc,LastOtherDeviceUtc=lastOtherUtc,EndReason=endReason,LastError=LastError,TcpConnections=tcpConnections,OtherDeviceConnections=otherConnections,HttpResponses=httpResponses,TlsConnections=tlsConnections,ActiveConnections=clients.Count,ActiveUploads=inFlightUploads,ReservedUploadBytes=reservedBytes,AcceptedFiles=AcceptedCount,AcceptedBytes=TotalBytes,Finished=Finished,Events=networkEvents.ToArray()};}
        }
        void Run() {
            try {
                while(!stop&&lifetime.Elapsed.TotalSeconds<lifetimeSeconds){
                    if(!listener.Pending()){Thread.Sleep(30);continue;}
                    var client=listener.AcceptTcpClient();var peer=((IPEndPoint)client.Client.RemoteEndPoint).Address;
                    var context=new Context{Peer=IPAddress.IsLoopback(peer)||localAddresses.Contains(peer.ToString())?"ThisPC":"OtherDevice"};
                    Interlocked.Increment(ref tcpConnections);if(context.Peer=="OtherDevice"){Interlocked.Increment(ref otherConnections);lastOtherUtc=DateTime.UtcNow.ToString("o");}
                    Record(context,"TcpAccepted",0,null);
                    lock(gate){if(clients.Count>=16){Record(context,"CapacityLimit",0,"TooManyConnections");client.Close();continue;}clients.Add(client);drained.Reset();}
                    ThreadPool.QueueUserWorkItem(delegate(object ignored){HandleConnection(client,context);});
                }
                endReason=stop?"StoppedByUser":"Expired";
            }catch{if(!stop){LastError="ReceiverStoppedUnexpectedly";endReason="ListenerFailed";}else{endReason="StoppedByUser";}}
            finally{listener.Stop();CloseClients();lock(gate){listenerStopped=true;Finished=clients.Count==0;}}
        }
        void HandleConnection(TcpClient client,Context context) {
            try{client.ReceiveTimeout=5000;client.SendTimeout=15000;if(!stop)Handle(client.GetStream(),context);}
            catch{LastError="RequestInterruptedOrInvalid";Record(context,"RequestInterrupted",0,"ReadTimeoutOrConnectionClosed");}
            finally{client.Close();lock(gate){clients.Remove(client);if(clients.Count==0){drained.Set();if(listenerStopped)Finished=true;}}}
        }
        void CloseClients(){TcpClient[] current;lock(gate){current=new TcpClient[clients.Count];clients.CopyTo(current);}foreach(var client in current){try{client.Close();}catch{}}}
        void Reply(Stream stream,Context context,int code,string type,byte[] data) {
            string reason=code==200?"OK":code==201?"Created":code==404?"Not Found":code==413?"Payload Too Large":code==415?"Unsupported Media Type":code==429?"Too Many Requests":"Bad Request";
            string headers="HTTP/1.1 "+code+" "+reason+"\r\nContent-Type: "+type+"\r\nContent-Length: "+data.Length+"\r\nConnection: close\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; media-src 'self' blob:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'\r\n\r\n";
            var bytes=Encoding.ASCII.GetBytes(headers);stream.Write(bytes,0,bytes.Length);stream.Write(data,0,data.Length);Interlocked.Increment(ref httpResponses);Record(context,"HttpResponseSent",code,null);
        }
        void Error(Stream s,Context c,int code,string message){Record(c,"RequestRejected",code,message);Reply(s,c,code,"application/json; charset=utf-8",Encoding.UTF8.GetBytes("{\"error\":\""+message+"\"}"));}
        void Handle(NetworkStream stream,Context context) {
            var header=new List<byte>();var clock=Stopwatch.StartNew();
            while(header.Count<16384&&clock.Elapsed.TotalSeconds<20){
                int b=stream.ReadByte();if(b<0){Record(context,"ConnectionClosed",0,header.Count==0?"BeforeHttpRequest":"IncompleteHeaders");return;}
                context.HeaderBytes++;
                if(header.Count==0&&b==0x16){Interlocked.Increment(ref tlsConnections);Record(context,"TlsOnHttpPort",0,"HttpsRequestedOnHttpListener");return;}
                header.Add((byte)b);int n=header.Count;if(n>=4&&header[n-4]==13&&header[n-3]==10&&header[n-2]==13&&header[n-1]==10)break;
            }
            if(header.Count>=16384||clock.Elapsed.TotalSeconds>=20){Error(stream,context,400,"HeaderLimit");return;}
            var lines=Encoding.ASCII.GetString(header.ToArray()).Split(new[]{"\r\n"},StringSplitOptions.None);
            var first=lines[0].Split(' ');if(first.Length!=3){Error(stream,context,400,"InvalidRequest");return;}
            context.Method=first[0]=="GET"||first[0]=="POST"||first[0]=="OPTIONS"?first[0]:"Other";
            var headers=new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
            foreach(string line in lines){int split=line.IndexOf(':');if(split>0){string key=line.Substring(0,split).Trim();if(headers.ContainsKey(key)){Error(stream,context,400,"DuplicateHeader");return;}headers[key]=line.Substring(split+1).Trim();}}
            string agent;if(headers.TryGetValue("User-Agent",out agent)){var match=Regex.Match(agent,@"(Firefox|Chrome|Safari)/(\d+)");if(match.Success){context.Browser=match.Groups[1].Value;Int32.TryParse(match.Groups[2].Value,out context.BrowserMajor);}}
            string attempt;if(headers.TryGetValue("X-Upload-Attempt",out attempt)&&Regex.IsMatch(attempt,@"\A[a-f0-9]{32}\z"))context.AttemptId=attempt;
            string host;if(!headers.TryGetValue("Host",out host)||!String.Equals(host,new Uri(origin).Authority,StringComparison.OrdinalIgnoreCase)){Error(stream,context,400,"InvalidHost");return;}
            string route=first[1];if(!route.StartsWith(prefix,StringComparison.Ordinal)){context.Route="Unknown";Error(stream,context,404,"NotFound");return;}route=route.Substring(prefix.Length);
            context.Route=route==""?"PhonePage":route=="pc"?"QrPage":route=="health"?"Health":route=="upload"?"Upload":route=="web.css"?"Style":route=="phone.js"||route=="transfer.js"||route=="pc.js"||route=="qrcode.min.js"?"Script":"Unknown";
            Record(context,"HttpRequest",0,null);
            if(first[0]=="GET"){
                if(route=="health"){Reply(stream,context,200,"application/json; charset=utf-8",Encoding.UTF8.GetBytes("{\"ready\":true}"));return;}
                string file=null,type="text/html; charset=utf-8";
                if(route=="")file="phone.html";else if(route=="pc")file="pc.html";
                else if(route=="phone.js"||route=="transfer.js"||route=="pc.js"){file=route;type="application/javascript; charset=utf-8";}
                else if(route=="web.css"){file=route;type="text/css; charset=utf-8";}
                else if(route=="qrcode.min.js"){file="vendor/qrcodejs/qrcode.min.js";type="application/javascript; charset=utf-8";}
                if(file==null){Error(stream,context,404,"NotFound");return;}
                Reply(stream,context,200,type,File.ReadAllBytes(Path.Combine(webRoot,file.Replace('/',Path.DirectorySeparatorChar))));return;
            }
            if(first[0]!="POST"||route!="upload"){Error(stream,context,404,"NotFound");return;}
            string value;if(headers.TryGetValue("Origin",out value)&&value!=origin){Error(stream,context,400,"InvalidOrigin");return;}
            if(headers.ContainsKey("Transfer-Encoding")){Error(stream,context,400,"LengthRequired");return;}
            long length;if(!headers.TryGetValue("Content-Length",out value)||!Int64.TryParse(value,out length)||length<=0){Error(stream,context,400,"LengthRequired");return;}
            if(length>MaxFileBytes){Error(stream,context,413,"FileTooLarge");return;}
            context.ExpectedBytes=length;
            bool reserved=false;
            lock(gate){if(AcceptedCount+inFlightUploads<12&&TotalBytes+reservedBytes+length<=536870912){inFlightUploads++;reservedBytes+=length;reserved=true;}}
            if(!reserved){Error(stream,context,429,"ReceiverLimit");return;}
            Record(context,"UploadStarted",0,null);
            string staging=Path.Combine(directory,"physical","incoming-"+Guid.NewGuid().ToString("N")+".upload");
            try {
                Directory.CreateDirectory(Path.GetDirectoryName(staging));
                using(var output=new FileStream(staging,FileMode.CreateNew,FileAccess.Write,FileShare.None)){
                    var buffer=new byte[65536];long remaining=length;
                    while(remaining>0){if(stop||clock.Elapsed.TotalSeconds>180)throw new IOException("Transfer cancelled.");int read=stream.Read(buffer,0,(int)Math.Min(buffer.Length,remaining));if(read==0)throw new EndOfStreamException();output.Write(buffer,0,read);remaining-=read;context.BodyBytes+=read;}
                }
                ReceivedMedia media;
                try{media=ImportFile(staging,directory,"PhoneBrowser");}catch(InvalidDataException){Error(stream,context,415,"UnsupportedMedia");return;}
                media.ClientSentUtc=Header(headers,"X-Client-Sent-Utc",80);media.CaptureStartedUtc=Header(headers,"X-Capture-Started-Utc",80);media.CaptureEndedUtc=Header(headers,"X-Capture-Ended-Utc",80);
                string note=Header(headers,"X-Note",4096);try{media.Note=Uri.UnescapeDataString(note);}catch{media.Note="";}if(media.Note.Length>1000)media.Note=media.Note.Substring(0,1000);
                media.PreviewConfirmed=Header(headers,"X-Preview-Confirmed",8)=="true";value=Header(headers,"X-Heard-Noise",16);media.HeardNoise=value=="Yes"||value=="No"?value:"Unknown";
                lock(gate){AcceptedCount++;TotalBytes+=length;inFlightUploads--;reservedBytes-=length;reserved=false;}
                Received.Enqueue(media);Record(context,"UploadSaved",201,null);Reply(stream,context,201,"application/json; charset=utf-8",Encoding.UTF8.GetBytes("{\"received\":true,\"id\":\""+media.Id+"\"}"));
            }finally{if(reserved){lock(gate){inFlightUploads--;reservedBytes-=length;}}if(File.Exists(staging))File.Delete(staging);}
        }
        static string Header(Dictionary<string,string> headers,string key,int maximum){string value;return headers.TryGetValue(key,out value)?value.Substring(0,Math.Min(value.Length,maximum)):"";}
        public static ReceivedMedia ImportFile(string source,string sessionDirectory,string sourceKind) {
            var info=new FileInfo(source);if(info.Length<12||info.Length>MaxFileBytes)throw new InvalidDataException("Media size is invalid.");
            var bytes=new byte[64];using(var input=File.OpenRead(source)){input.Read(bytes,0,bytes.Length);}
            string extension=null,mime=null,kind="audio";
            if(Encoding.ASCII.GetString(bytes,0,4)=="RIFF"&&Encoding.ASCII.GetString(bytes,8,4)=="WAVE"){extension="wav";mime="audio/wav";}
            else if(Encoding.ASCII.GetString(bytes,4,4)=="ftyp"){
                string brand=Encoding.ASCII.GetString(bytes,8,4);
                if(brand=="M4A "||brand=="M4B "){extension="m4a";mime="audio/mp4";}
                else{extension=brand=="qt  "?"mov":"mp4";mime=extension=="mov"?"video/quicktime":"video/mp4";kind="video";}
            }else if(bytes[0]==0x1a&&bytes[1]==0x45&&bytes[2]==0xdf&&bytes[3]==0xa3){extension="webm";mime="video/webm";kind="video";}
            else if(Encoding.ASCII.GetString(bytes,0,4)=="OggS"){extension="ogg";mime="audio/ogg";}
            else if(Encoding.ASCII.GetString(bytes,0,3)=="ID3"||(bytes[0]==255&&(bytes[1]&224)==224)){
                extension=bytes[0]==255&&(bytes[1]&246)==240?"aac":"mp3";mime=extension=="aac"?"audio/aac":"audio/mpeg";
            }
            if(extension==null)throw new InvalidDataException("Unsupported media signature.");
            string id=Guid.NewGuid().ToString("N"),relative="physical/"+id+"/source."+extension;
            string root=Path.GetFullPath(sessionDirectory);string target=Path.Combine(root,relative.Replace('/',Path.DirectorySeparatorChar));Directory.CreateDirectory(Path.GetDirectoryName(target));
            try{File.Copy(source,target,false);string hash;using(var sha=SHA256.Create())using(var file=File.OpenRead(target)){hash=BitConverter.ToString(sha.ComputeHash(file)).Replace("-","");}
                return new ReceivedMedia {Id=id,RelativePath=relative,Sha256=hash,Bytes=info.Length,MimeType=mime,Kind=kind,ReceivedUtc=DateTime.UtcNow.ToString("o"),Source=sourceKind,HeardNoise="Unknown",Note=""};
            }catch{if(File.Exists(target))File.Delete(target);throw;}
        }
        public void Dispose(){stop=true;listener.Stop();CloseClients();if(!thread.Join(5000)||!drained.Wait(5000))throw new TimeoutException("Receiver did not stop.");}
    }
}
