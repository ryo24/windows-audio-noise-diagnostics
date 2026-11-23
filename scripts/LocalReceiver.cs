using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
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
        volatile bool stop; volatile TcpClient active;
        public readonly ConcurrentQueue<ReceivedMedia> Received=new ConcurrentQueue<ReceivedMedia>();
        public readonly string Url; public volatile bool Finished; public volatile int AcceptedCount; public long TotalBytes;
        public string LastError; public int Port {get;private set;}
        public static bool IsLocalAddress(string address) {
            IPAddress ip;if(!IPAddress.TryParse(address,out ip)||ip.AddressFamily!=AddressFamily.InterNetwork)return false;
            var b=ip.GetAddressBytes();return b[0]==127||b[0]==10||(b[0]==192&&b[1]==168)||(b[0]==172&&b[1]>=16&&b[1]<=31);
        }
        public static LocalReceiver Start(string address,string directory,string webRoot,int lifetimeSeconds) {return new LocalReceiver(address,directory,webRoot,lifetimeSeconds);}
        LocalReceiver(string address,string directory,string webRoot,int seconds) {
            if(!IsLocalAddress(address))throw new ArgumentException("Choose a private IPv4 address or loopback.");
            if(seconds<1||seconds>900)throw new ArgumentOutOfRangeException("seconds");
            this.directory=Path.GetFullPath(directory);this.webRoot=Path.GetFullPath(webRoot);lifetimeSeconds=seconds;
            var random=new byte[24];using(var rng=RandomNumberGenerator.Create()){rng.GetBytes(random);}
            string token=Convert.ToBase64String(random).TrimEnd('=').Replace('+','-').Replace('/','_');
            prefix="/s/"+token+"/";
            listener=new TcpListener(IPAddress.Parse(address),0);listener.Start(4);Port=((IPEndPoint)listener.LocalEndpoint).Port;
            origin="http://"+address+":"+Port;Url=origin+prefix;
            thread=new Thread(Run);thread.IsBackground=true;thread.Start();
        }
        void Run() {
            try {
                while(!stop&&lifetime.Elapsed.TotalSeconds<lifetimeSeconds){
                    if(!listener.Pending()){Thread.Sleep(50);continue;}
                    using(var client=listener.AcceptTcpClient()){
                        active=client;client.ReceiveTimeout=15000;client.SendTimeout=15000;
                        try{Handle(client.GetStream());}catch{LastError="RequestInterruptedOrInvalid";}finally{active=null;}
                    }
                }
            }catch{if(!stop)LastError="ReceiverStoppedUnexpectedly";}
            finally{listener.Stop();Finished=true;}
        }
        static void Reply(Stream stream,int code,string type,byte[] data) {
            string reason=code==200?"OK":code==201?"Created":code==404?"Not Found":code==413?"Payload Too Large":code==415?"Unsupported Media Type":code==429?"Too Many Requests":"Bad Request";
            string headers="HTTP/1.1 "+code+" "+reason+"\r\nContent-Type: "+type+"\r\nContent-Length: "+data.Length+"\r\nConnection: close\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; media-src 'self' blob:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'\r\n\r\n";
            var bytes=Encoding.ASCII.GetBytes(headers);stream.Write(bytes,0,bytes.Length);stream.Write(data,0,data.Length);
        }
        static void Error(Stream s,int code,string message){Reply(s,code,"application/json; charset=utf-8",Encoding.UTF8.GetBytes("{\"error\":\""+message+"\"}"));}
        void Handle(NetworkStream stream) {
            var header=new List<byte>();var clock=Stopwatch.StartNew();
            while(header.Count<16384&&clock.Elapsed.TotalSeconds<20){int b=stream.ReadByte();if(b<0)return;header.Add((byte)b);int n=header.Count;if(n>=4&&header[n-4]==13&&header[n-3]==10&&header[n-2]==13&&header[n-1]==10)break;}
            if(header.Count>=16384||clock.Elapsed.TotalSeconds>=20){Error(stream,400,"HeaderLimit");return;}
            var lines=Encoding.ASCII.GetString(header.ToArray()).Split(new[]{"\r\n"},StringSplitOptions.None);
            var first=lines[0].Split(' ');if(first.Length!=3){Error(stream,400,"InvalidRequest");return;}
            var headers=new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
            foreach(string line in lines){int split=line.IndexOf(':');if(split>0){string key=line.Substring(0,split).Trim();if(headers.ContainsKey(key)){Error(stream,400,"DuplicateHeader");return;}headers[key]=line.Substring(split+1).Trim();}}
            string host;if(!headers.TryGetValue("Host",out host)||!String.Equals(host,new Uri(origin).Authority,StringComparison.OrdinalIgnoreCase)){Error(stream,400,"InvalidHost");return;}
            string route=first[1];if(!route.StartsWith(prefix,StringComparison.Ordinal)){Error(stream,404,"NotFound");return;}route=route.Substring(prefix.Length);
            if(first[0]=="GET"){
                string file=null,type="text/html; charset=utf-8";
                if(route=="")file="phone.html";else if(route=="pc")file="pc.html";
                else if(route=="phone.js"||route=="pc.js"){file=route;type="application/javascript; charset=utf-8";}
                else if(route=="web.css"){file=route;type="text/css; charset=utf-8";}
                else if(route=="qrcode.min.js"){file="vendor/qrcodejs/qrcode.min.js";type="application/javascript; charset=utf-8";}
                if(file==null){Error(stream,404,"NotFound");return;}
                Reply(stream,200,type,File.ReadAllBytes(Path.Combine(webRoot,file.Replace('/',Path.DirectorySeparatorChar))));return;
            }
            if(first[0]!="POST"||route!="upload"){Error(stream,404,"NotFound");return;}
            string value;if(headers.TryGetValue("Origin",out value)&&value!=origin){Error(stream,400,"InvalidOrigin");return;}
            if(headers.ContainsKey("Transfer-Encoding")){Error(stream,400,"LengthRequired");return;}
            long length;if(!headers.TryGetValue("Content-Length",out value)||!Int64.TryParse(value,out length)||length<=0){Error(stream,400,"LengthRequired");return;}
            if(length>MaxFileBytes){Error(stream,413,"FileTooLarge");return;}
            if(AcceptedCount>=12||TotalBytes+length>536870912){Error(stream,429,"ReceiverLimit");return;}
            string staging=Path.Combine(directory,"physical","incoming-"+Guid.NewGuid().ToString("N")+".upload");
            Directory.CreateDirectory(Path.GetDirectoryName(staging));
            try {
                using(var output=new FileStream(staging,FileMode.CreateNew,FileAccess.Write,FileShare.None)){
                    var buffer=new byte[65536];long remaining=length;
                    while(remaining>0){if(stop||clock.Elapsed.TotalSeconds>180)throw new IOException("Transfer cancelled.");int read=stream.Read(buffer,0,(int)Math.Min(buffer.Length,remaining));if(read==0)throw new EndOfStreamException();output.Write(buffer,0,read);remaining-=read;}
                }
                ReceivedMedia media;
                try{media=ImportFile(staging,directory,"PhoneBrowser");}catch(InvalidDataException){Error(stream,415,"UnsupportedMedia");return;}
                media.ClientSentUtc=Header(headers,"X-Client-Sent-Utc",80);media.CaptureStartedUtc=Header(headers,"X-Capture-Started-Utc",80);media.CaptureEndedUtc=Header(headers,"X-Capture-Ended-Utc",80);
                string note=Header(headers,"X-Note",4096);try{media.Note=Uri.UnescapeDataString(note);}catch{media.Note="";}if(media.Note.Length>1000)media.Note=media.Note.Substring(0,1000);
                media.PreviewConfirmed=Header(headers,"X-Preview-Confirmed",8)=="true";
                value=Header(headers,"X-Heard-Noise",16);media.HeardNoise=value=="Yes"||value=="No"?value:"Unknown";
                Received.Enqueue(media);AcceptedCount++;TotalBytes+=length;
                Reply(stream,201,"application/json; charset=utf-8",Encoding.UTF8.GetBytes("{\"received\":true,\"id\":\""+media.Id+"\"}"));
            }finally{if(File.Exists(staging))File.Delete(staging);}
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
        public void Dispose(){stop=true;listener.Stop();var client=active;if(client!=null)client.Close();if(!thread.Join(5000))throw new TimeoutException("Receiver did not stop.");}
    }
}
