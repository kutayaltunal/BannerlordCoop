using Common;
using Common.Logging;
using Common.Messaging;
using Common.Network;
using Common.PacketHandlers;
using Common.Serialization;
using Coop.Core.Client.Messages;
using Coop.Core.Common.Network;
using Coop.Core.Common.Services.Connection.Messages;
using Coop.Core.Common.Session.Messages;
using GameInterface.Services.GameDebug.Messages;
using LiteNetLib;
using Serilog;
using System;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Threading;

namespace Coop.Core.Client;

/// <summary>
/// Client used for Coop
/// </summary>
public interface ICoopClient : IRelayNetwork, IUpdateable, INetEventListener, IDisposable
{
}

/// <inheritdoc cref="ICoopClient"/>
public class CoopClient : CoopNetworkBase, ICoopClient
{
    public override int Priority => 0;
    public IPEndPoint ServerEndpoint { get; private set; }

    private static readonly ILogger Logger = LogManager.GetLogger<CoopClient>();

    private readonly IMessageBroker messageBroker;
    private readonly IPacketManager packetManager;
    private readonly IMessagePacketHandler messagePacketHandler;
    private bool isConnected = false;
    private bool reconnectPending = false;
    private bool preferIPv6OnReconnect = false;
    private DateTime reconnectAfter = DateTime.MinValue;

    public CoopClient(
        INetworkConfig config,
        IMessageBroker messageBroker,
        IPacketManager packetManager,
        IMessagePacketHandler messagePacketHandler,
        ICommonSerializer serializer,
        IReliableMessageBatcher<NetPeer> reliableMessageBatcher,
        CancellationTokenSource sessionCancellation)
        : base(config, serializer, reliableMessageBatcher, sessionCancellation)
    {
        this.messageBroker = messageBroker;
        this.packetManager = packetManager;
        this.messagePacketHandler = messagePacketHandler;
    }

    public override void OnConnectionRequest(ConnectionRequest request)
    {
        request.Reject();
    }

    public override void OnNetworkError(IPEndPoint endPoint, SocketError socketError)
    {
        // Common during auto-connect: server not yet listening when client attempts connection.
        // Log and continue — LiteNetLib will keep retrying within the DisconnectTimeout window.
        Logger.Warning("Network error from {EndPoint}: {SocketError}", endPoint, socketError);
    }

    public override void OnNetworkLatencyUpdate(NetPeer peer, int latency)
    {
        
    }

    public override void OnNetworkReceive(NetPeer peer, NetPacketReader reader, byte channelNumber, DeliveryMethod deliveryMethod)
    {
        try
        {
            object received = serializer.Deserialize(reader.GetRemainingBytes());

            if (received is IPacket packet)
            {
                packetManager.HandleReceive(peer, packet);
            }
            else if (received is IMessage message)
            {
                messagePacketHandler.PublishEvent(peer, message);
            }
            else
            {
                Logger.Error("Received payload deserialized to neither IPacket nor IMessage: {Type}", received?.GetType());
            }
        }
        catch (Exception ex)
        {
            Logger.Error(ex, "Failed to process packet");
        }
    }

    public override void OnNetworkReceiveUnconnected(IPEndPoint remoteEndPoint, NetPacketReader reader, UnconnectedMessageType messageType)
    {
        Logger.Warning("Received unconnected message from {EndPoint}", remoteEndPoint);
    }

    public override void OnPeerConnected(NetPeer peer)
    {
        if(isConnected == false)
        {
            isConnected = true;

            messageBroker.Publish(this, new SendInformationMessage("Connected! Please wait for transfer"));
            messageBroker.Publish(this, new NetworkConnected());
        }
    }

    public override void OnPeerDisconnected(NetPeer peer, DisconnectInfo disconnectInfo)
    {
        if (!isConnected && disconnectInfo.Reason == DisconnectReason.ConnectionRejected)
        {
            var rejectCode = ReadRejectCode(disconnectInfo);
            reconnectPending = false;

            string message = GetRejectMessage(rejectCode);

            Logger.Warning("Connection rejected by server: {Reason}", rejectCode);
            GameThread.RunSafe(() =>
            {
                messageBroker.Publish(this, new SendPopupMessage(message));
                messageBroker.Publish(this, new EndCoopMode());
            }, context: "ConnectionRejected");
            return;
        }

        if (isConnected == true)
        {
            isConnected = false;
            var serverReason = ReadDisconnectReason(disconnectInfo);
            messageBroker.Publish(this, new SendInformationMessage(disconnectInfo.Reason.ToString()));
            messageBroker.Publish(this, new NetworkDisconnected(disconnectInfo, serverReason));
        }
        else
        {
            // During auto-connect, the client may attempt to connect before the server has finished
            // registering game objects and opened joining. Schedule a retry until it's accepted.
            Logger.Warning("Connection attempt failed ({Reason}), retrying in 3 seconds...", disconnectInfo.Reason);
            reconnectPending = true;
            reconnectAfter = DateTime.UtcNow.AddSeconds(3);
        }
    }

    private static string ReadDisconnectReason(DisconnectInfo disconnectInfo)
    {
        var data = disconnectInfo.AdditionalData;
        if (data == null || data.IsNull) return null;

        try
        {
            if (disconnectInfo.Reason != DisconnectReason.RemoteConnectionClose) return null;
            string reason = data.GetString(128);
            return data.EndOfData ? reason : null;
        }
        catch (Exception)
        {
            return null;
        }
        finally
        {
            data.Recycle();
        }
    }

    private static string GetRejectMessage(ConnectionRejectCode rejectCode)
    {
        switch (rejectCode)
        {
            case ConnectionRejectCode.IncorrectPassword:
                return "The server password is incorrect.";
            case ConnectionRejectCode.ServerRestarting:
                return "The server is restarting. Try again in a few minutes.";
            default:
                return "The server rejected the connection.";
        }
    }

    private static ConnectionRejectCode ReadRejectCode(DisconnectInfo disconnectInfo)
    {
        var data = disconnectInfo.AdditionalData;
        if (data == null || data.IsNull) return ConnectionRejectCode.None;

        try
        {
            if (data.TryGetByte(out var raw) && Enum.IsDefined(typeof(ConnectionRejectCode), raw))
            {
                return (ConnectionRejectCode)raw;
            }

            return ConnectionRejectCode.None;
        }
        finally
        {
            data.Recycle();
        }
    }

    public override void Start()
    {
        messageBroker.Publish(this, new SendInformationMessage("Connecting..."));

        if (isConnected)
        {
            return;
        }

        reconnectPending = false;
        preferIPv6OnReconnect = false;
        reconnectAfter = DateTime.MinValue;

        IPAddress ip;
        try
        {
            ip = ResolveConnectAddress(Config.Address, preferIPv6: false);
        }
        catch (Exception ex)
        {
            Logger.Error(ex, "Failed to resolve server address '{Address}' on port {Port}", Config.Address, Config.Port);
            throw;
        }

        ServerEndpoint = new IPEndPoint(ip, Config.Port);

        if (!HasCompatibleLiteNetLib()) return;

        netManager.IPv6Enabled = Socket.OSSupportsIPv6;
        netManager.Start();
        StartNetworkPoller();

        Logger.Information("Attempting connection to {Endpoint} ({AddressFamily})...", ServerEndpoint, ServerEndpoint.AddressFamily);
        netManager.Connect(ServerEndpoint, Config.Token);
    }

    private bool HasCompatibleLiteNetLib()
    {
        if (typeof(NetManager).GetMethod(nameof(NetManager.PollEvents), new[] { typeof(int) }) != null)
            return true;

        var assembly = typeof(NetManager).Assembly;
        var path = assembly.Location;
        string sha256 = "unavailable";
        try
        {
            using (var stream = File.OpenRead(path))
            using (var hasher = SHA256.Create())
                sha256 = BitConverter.ToString(hasher.ComputeHash(stream)).Replace("-", "").ToLowerInvariant();
        }
        catch (Exception ex) when (ex is IOException || ex is UnauthorizedAccessException || ex is ArgumentException)
        {
            Logger.Warning(ex, "Could not hash loaded LiteNetLib assembly at {Path}", path);
        }

        Logger.Error("Loaded LiteNetLib lacks NetManager.PollEvents(Int32): path={Path}, version={Version}, sha256={Sha256}",
            path, assembly.GetName().Version, sha256);
        // Let the join caller return before teardown, and keep its popup after session cancellation.
        using (GameThread.ActivateCancellation(CancellationToken.None))
        {
            GameThread.EnqueueSafe(() =>
            {
                messageBroker.Publish(this, new SendPopupMessage(
                    "Bannerlord loaded a LiteNetLib.dll that Coop cannot use. Close the game, check Coop_client.log for its loaded path, then remove or update that copy and reinstall Coop. If joining still fails, send the new log to support."));
                messageBroker.Publish(this, new EndCoopMode());
            }, context: "IncompatibleLiteNetLib");
        }
        return false;
    }

    private static IPAddress ResolveConnectAddress(string address, bool preferIPv6)
    {
        if (string.IsNullOrWhiteSpace(address))
            throw new ArgumentException("Server address cannot be null or empty.", nameof(address));

        string normalized = NormalizeAddressString(address);

        if (IPAddress.TryParse(normalized, out var parsed))
        {
            parsed = NormalizeIpAddress(parsed);
            if (parsed.AddressFamily == AddressFamily.InterNetworkV6 && !Socket.OSSupportsIPv6)
            {
                Logger.Error("IPv6 address '{Address}' was specified, but the operating system does not support IPv6", address);
                throw new InvalidOperationException($"IPv6 is not supported on this machine for address: {address}");
            }

            return parsed;
        }

        var addresses = Dns.GetHostAddresses(normalized)
            .Select(NormalizeIpAddress)
            .Where(IsUsableConnectAddress)
            .ToArray();

        var preferredFamily = preferIPv6 && Socket.OSSupportsIPv6
            ? AddressFamily.InterNetworkV6
            : AddressFamily.InterNetwork;

        var fallbackFamily = preferredFamily == AddressFamily.InterNetworkV6
            ? AddressFamily.InterNetwork
            : AddressFamily.InterNetworkV6;

        return addresses.FirstOrDefault(x => x.AddressFamily == preferredFamily)
            ?? addresses.FirstOrDefault(x => x.AddressFamily == fallbackFamily)
            ?? throw new InvalidOperationException($"Could not resolve usable IPv4/IPv6 address for '{address}'");
    }

    private static string NormalizeAddressString(string address)
    {
        string trimmed = address.Trim();
        if (trimmed.Length >= 2 && trimmed[0] == '[' && trimmed[trimmed.Length - 1] == ']')
        {
            return trimmed.Substring(1, trimmed.Length - 2).Trim();
        }

        return trimmed;
    }

    private static IPAddress NormalizeIpAddress(IPAddress address)
    {
        // LiteNetLib binds separate IPv4 and IPv6 sockets (with DualMode = false on the IPv6 socket),
        // so IPv4-mapped IPv6 addresses (::ffff:a.b.c.d) must be normalized to InterNetwork (IPv4)
        // so LiteNetLib routes them through its IPv4 socket instead of failing with AddressNotAvailable.
        if (address != null &&
            address.AddressFamily == AddressFamily.InterNetworkV6 &&
            address.IsIPv4MappedToIPv6)
        {
            return address.MapToIPv4();
        }

        return address;
    }

    private static bool IsUsableConnectAddress(IPAddress address)
    {
        if (address.AddressFamily == AddressFamily.InterNetwork)
            return true;

        if (address.AddressFamily == AddressFamily.InterNetworkV6)
        {
            return Socket.OSSupportsIPv6
                && !address.IsIPv6LinkLocal
                && !address.IsIPv6Multicast
                && !address.IsIPv6SiteLocal;
        }

        return false;
    }

    public override void Update(TimeSpan frameTime)
    {
        netManager.PollEvents();

        // Send any sub-budget aggregated messages so nothing waits longer than one poll interval.
        FlushPendingMessages();

        if (reconnectPending && DateTime.UtcNow >= reconnectAfter)
        {
            reconnectPending = false;
            preferIPv6OnReconnect = !preferIPv6OnReconnect;

            try
            {
                var ip = ResolveConnectAddress(Config.Address, preferIPv6: preferIPv6OnReconnect);
                ServerEndpoint = new IPEndPoint(ip, Config.Port);
            }
            catch (Exception ex)
            {
                Logger.Warning(ex, "Could not re-resolve '{Address}' during reconnect; reusing {Endpoint}", Config.Address, ServerEndpoint);
            }

            messageBroker.Publish(this, new SendInformationMessage("Retrying connection to server..."));
            Logger.Information("Retrying connection to {Endpoint}...", ServerEndpoint);
            netManager.Connect(ServerEndpoint, Config.Token);
        }
    }

    public override void SendAll(IPacket packet)
    {
        SendAll(netManager, packet);
    }

    public override void SendAllBut(NetPeer netPeer, IPacket packet)
    {
        SendAllBut(netManager, netPeer, packet);
    }
}
