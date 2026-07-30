#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <tf2>
#include <adt_array>

#undef REQUIRE_PLUGIN
#include <afkmanager>
#include <dgm_api>
#define REQUIRE_PLUGIN

#include <plugin_statistics>

#define BASE_STR_LEN 128

#define JOIN_TEAM_BLU "blue"
#define JOIN_TEAM_RED "red"
#define JOIN_TEAM_AUTO "auto"
#define JOIN_TEAM_SPECTATOR "spectate"

public Plugin myinfo = {
    name = "Spectate When Full",
    author = "Eric Zhang",
    description = "Allows players to spectate when the server is full.",
    version = "1.0",
    url = "https://ericaftereric.top/"
};

ConVar cvarMaxPlayersInGame;
ConVar cvarPutSpecInAutoJoin;
ConVar cvarStatisticsLogging;

ConVar cvarVisibleMaxPlayers;
ConVar cvarSourceTVEnabled;
ConVar cvarReplayEnabled;

// store userid inside as it will persist during map resets
enum struct PlayerQueue {
    ArrayList clients;

    void Init() {
        this.clients = new ArrayList();
    }

    void Deinit() {
        delete this.clients;
    }

    void OfferViaUserId(int userId) {
        this.clients.Push(userId);
    }

    void Offer(int client) {
        this.OfferViaUserId(GetClientUserId(client));
    }

    int Poll() {
        if (this.IsEmpty()) {
            return -1;
        }
        int value = this.clients.Get(0);
        this.clients.Erase(0);
        return GetClientOfUserId(value);
    }

    bool RemoveFromQueue(int client) {
        return this.RemoveUserIdFromQueue(GetClientUserId(client));
    }

    bool RemoveUserIdFromQueue(int userId) {
        int index = this.clients.FindValue(userId);
        if (index == -1) {
            return false;
        }
        this.clients.Erase(index);
        return true;
    }

    bool InQueue(int client) {
        return this.clients.FindValue(GetClientUserId(client)) != -1;
    }

    void Clear() {
        this.clients.Clear();
    }

    bool IsEmpty() {
        return this.clients.Length == 0;
    }

    int GetLength() {
        return this.clients.Length;
    }
}

PlayerQueue waitQueue;
// queue operations (poll/offer) are useless here but i am reusing this struct
PlayerQueue clientsInGame;

public void OnPluginStart() {
    LoadTranslations("spec-when-full.phrases.txt");

    waitQueue.Init();
    clientsInGame.Init();

    cvarMaxPlayersInGame = CreateConVar("sm_fullspec_maxplayers_in_game", "24", "Maximum amount of players allowed in game. Set to -1 to disable.");
    cvarPutSpecInAutoJoin = CreateConVar("sm_fullspec_put_spec_in_autojoin", "1", "Automatically put spectators into autojoin when server is full.");
    cvarStatisticsLogging = CreateConVar(
        "sm_spec_when_full_log",
        "0",
        "Record client and team population snapshots through kogasa-statistics.",
        FCVAR_DONTRECORD,
        true,
        0.0,
        true,
        1.0
    );

    PluginStats_Init("spec_when_full_statistics_events");

    cvarVisibleMaxPlayers = FindConVar("sv_visiblemaxplayers");
    cvarSourceTVEnabled = FindConVar("tv_enable");
    cvarReplayEnabled = FindConVar("replay_enable");

    cvarMaxPlayersInGame.AddChangeHook(OnMaxPlayerCvarChanged);
    cvarVisibleMaxPlayers.AddChangeHook(OnMaxPlayerCvarChanged);

    RegConsoleCmd("sm_joinqueue", Cmd_AutoJoin, "Join the auto-join queue.");
    RegConsoleCmd("sm_joinq", Cmd_AutoJoin, "Join the auto-join queue.");
    RegConsoleCmd("sm_leavequeue", Cmd_LeaveAutoJoin, "Leave the auto-join queue.");
    RegConsoleCmd("sm_leaveq", Cmd_LeaveAutoJoin, "Leave the auto-join queue.");
    RegConsoleCmd("sm_checkautojoin", Cmd_CheckAutoJoinQueue, "See the auto join queue.");

#if defined DEBUG
    RegAdminCmd("sm_checkclientsingame", Cmd_CheckClientsInGame, ADMFLAG_CONFIG);
#endif

    AddCommandListener(OnClientJoinTeam, "jointeam");

    HookEvent("player_disconnect", Event_OnPlayerDisconnect);
    HookEvent("player_team", Event_OnPlayerTeam, EventHookMode_Post);

    AutoExecConfig();
    RebuildClientsInGame();
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int errMax) {
    MarkNativeAsOptional("DGM_GetGameModeKey");
    MarkNativeAsOptional("DGM_NormalizeMapName");
    MarkNativeAsOptional("DGM_CurrentNormalizedMap");
    return APLRes_Success;
}

public void OnMapStart() {
    PluginStats_OnMapStart();
}

public void OnClientConnected(int client) {
    LogPopulationSnapshot("client_connected", client);
}

public void OnClientPutInServer(int client) {
    if (!IsFakeClient(client)) {
        LogPopulationSnapshot("client_put_in_server", client);
    }
}

public void OnAllPluginsLoaded() {
    if (FindPluginByFile("reservedslots.smx") != INVALID_HANDLE) {
        LogMessage("Unloading reservedslots to prevent conflicts...");
        ServerCommand("sm plugins unload reservedslots");
    }
}

public void OnServerEnterHibernation() {
    waitQueue.Clear();
    clientsInGame.Clear();
}

public void OnConfigsExecuted() {
    RebuildClientsInGame();
    SetVisibleMaxPlayers();
}

public void OnPluginEnd() {
    PluginStats_Shutdown();
    waitQueue.Deinit();
    clientsInGame.Deinit();
}

public void OnMaxPlayerCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue) {
    SetVisibleMaxPlayers();
}

public void Event_OnPlayerDisconnect(Event event, const char[] name, bool dontBroadcast) {
    int userid = event.GetInt("userid");
    int client = GetClientOfUserId(userid);
    waitQueue.RemoveUserIdFromQueue(userid);
    clientsInGame.RemoveUserIdFromQueue(userid);
    LogPopulationSnapshot("client_disconnect", client, -1, -1, userid);
    SchedulePlayerChangeChecks();
}

public void Event_OnPlayerTeam(Event event, const char[] name, bool dontBroadcast) {
    if (event.GetBool("disconnect")) {
        return;
    }

    int userId = event.GetInt("userid");
    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client)) {
        return;
    }

    int oldTeam = event.GetInt("oldteam");
    int newTeam = event.GetInt("team");
    bool wasPlaying = IsPlayingTeam(oldTeam);
    bool isPlaying = IsPlayingTeam(newTeam);

    if (isPlaying) {
        if (!clientsInGame.InQueue(client)) {
            clientsInGame.Offer(client);
        }
        waitQueue.RemoveFromQueue(client);
        LogPopulationSnapshot("team_change", client, oldTeam, newTeam);
        return;
    }

    clientsInGame.RemoveFromQueue(client);
    int requeueUserId = 0;
    if (wasPlaying
        && newTeam == view_as<int>(TFTeam_Spectator)
        && cvarPutSpecInAutoJoin.BoolValue) {
        requeueUserId = userId;
    }
    SchedulePlayerChangeChecks(requeueUserId);
    LogPopulationSnapshot("team_change", client, oldTeam, newTeam);
}

void LogPopulationSnapshot(const char[] eventName, int client = 0, int oldTeam = -1, int newTeam = -1, int userId = 0) {
    if (cvarStatisticsLogging == null || !cvarStatisticsLogging.BoolValue) {
        return;
    }

    int red;
    int blue;
    int spectator;
    int unassigned;
    int other;
    GetTeamCounts(red, blue, spectator, unassigned, other);

    char steamId64[32];
    if (client > 0 && IsClientConnected(client)) {
        if (userId == 0) {
            userId = GetClientUserId(client);
        }
        if (IsClientAuthorized(client)) {
            GetClientAuthId(client, AuthId_SteamID64, steamId64, sizeof(steamId64));
        }
    }

    char message[512];
    FormatEx(
        message,
        sizeof(message),
        "event=%s|client=%d|userid=%d|steamid64=%s|old_team=%d|new_team=%d|playercount=%d|players_in_game=%d|red=%d|blu=%d|spectator=%d|unassigned=%d|other=%d|queue=%d|max=%d",
        eventName,
        client,
        userId,
        steamId64,
        oldTeam,
        newTeam,
        GetHumanCount(),
        GetPlayersInGame(),
        red,
        blue,
        spectator,
        unassigned,
        other,
        waitQueue.GetLength(),
        cvarMaxPlayersInGame.IntValue
    );
    PluginStats_LogMessage(message);
}

void GetTeamCounts(int &red, int &blue, int &spectator, int &unassigned, int &other) {
    for (int client = 1; client <= MaxClients; client++) {
        if (!IsClientInGame(client) || IsClientSourceTV(client) || IsClientReplay(client)) {
            continue;
        }

        switch (GetClientTeam(client)) {
            case view_as<int>(TFTeam_Unassigned): unassigned++;
            case view_as<int>(TFTeam_Spectator): spectator++;
            case view_as<int>(TFTeam_Red): red++;
            case view_as<int>(TFTeam_Blue): blue++;
            default: other++;
        }
    }
}

void SchedulePlayerChangeChecks(int requeueUserId = 0) {
    // Let disconnect and team-change state settle before filling the open slot.
    CreateTimer(1.0, Timer_RunPlayerCheck, requeueUserId);
}

public Action Timer_RunPlayerCheck(Handle timer, any requeueUserId) {
    RunPlayerChangeChecks();

    int client = GetClientOfUserId(requeueUserId);
    if (client > 0 && IsClientInGame(client)
        && GetClientTeam(client) == view_as<int>(TFTeam_Spectator)
        && cvarPutSpecInAutoJoin.BoolValue && !waitQueue.InQueue(client)) {
        waitQueue.Offer(client);
    }
    return Plugin_Continue;
}

void SetVisibleMaxPlayers() {
    if (cvarMaxPlayersInGame.IntValue == -1) {
        cvarVisibleMaxPlayers.IntValue = -1;
        return;
    }
    int maxHumanPlayers = GetActualMaxHumanPlayers();
    if (maxHumanPlayers <= cvarMaxPlayersInGame.IntValue) {
        LogError("Max human players is less than the maximum amount of players allowed in game.");
        cvarMaxPlayersInGame.IntValue = maxHumanPlayers;
        cvarVisibleMaxPlayers.IntValue = -1;
        return;
    }
    cvarVisibleMaxPlayers.IntValue = cvarMaxPlayersInGame.IntValue;
}

public Action OnClientJoinTeam(int client, const char[] command, int argc) {
    if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client)) {
        return Plugin_Continue;
    }
    if (cvarMaxPlayersInGame.IntValue == -1) {
        return Plugin_Continue;
    }
#if defined DEBUG
    int clientUserId = GetClientUserId(client);
    char clientName[MAX_NAME_LENGTH];
    GetClientName(client, clientName, sizeof(clientName));
#endif

    bool isServerOverloaded = GetHumanCount() >= cvarMaxPlayersInGame.IntValue;
    char team[BASE_STR_LEN];
    GetCmdArg(1, team, sizeof(team));

#if defined DEBUG
    LogMessage("Client %s (user id %d) issued \"jointeam %s\"", clientName, clientUserId, team);
#endif

    bool isClientJoiningGame = StrEqual(team, JOIN_TEAM_AUTO, false) || StrEqual(team, JOIN_TEAM_BLU, false) || StrEqual(team, JOIN_TEAM_RED, false);
    bool isClientJoiningSpec = StrEqual(team, JOIN_TEAM_SPECTATOR, false);
    if (!isServerOverloaded) {
#if defined DEBUG
        LogMessage("Server is not overloaded right now");
#endif
        if (isClientJoiningGame && !clientsInGame.InQueue(client)) {
#if defined DEBUG
            LogMessage("Adding client %s (user id %d) to clientsInGame", clientName, clientUserId);
#endif
            clientsInGame.Offer(client);
        }
        if (isClientJoiningSpec) {
#if defined DEBUG
            LogMessage("Removing client %s (user id %d) from clientsInGame", clientName, clientUserId);
#endif
            clientsInGame.RemoveFromQueue(client);
        }
        if (isClientJoiningSpec) {
            SchedulePlayerChangeChecks();
        } else {
            RunPlayerChangeChecks();
        }
        return Plugin_Continue;
    }
    bool putInAutoJoin = cvarPutSpecInAutoJoin.BoolValue;
    bool clientInClientList = clientsInGame.InQueue(client);
    int currentTeam = GetClientTeam(client);
    bool clientWasPlaying = currentTeam == view_as<int>(TFTeam_Red) || currentTeam == view_as<int>(TFTeam_Blue);
    if (isClientJoiningSpec) {
#if defined DEBUG
        LogMessage("Removing client %s (user id %d) from clientsInGame", clientName, clientUserId);
#endif
        clientsInGame.RemoveFromQueue(client);
        ChangeClientTeam(client, TFTeam_Spectator);
        int requeueUserId = 0;
        if (clientWasPlaying && putInAutoJoin) {
            requeueUserId = GetClientUserId(client);
            PrintToChat(client, "%t", "SPEC_WHEN_FULL_JOIN_SPEC_AUTO");
        } else if (IsServerFull() && !clientInClientList) {
            if (putInAutoJoin && !waitQueue.InQueue(client)) {
                waitQueue.Offer(client);
            }
            PrintToChat(client, "%t", putInAutoJoin ? "SPEC_WHEN_FULL_JOIN_SPEC_AUTO" : "SPEC_WHEN_FULL_JOIN_SPEC");
        }
        SchedulePlayerChangeChecks(requeueUserId);
        return Plugin_Handled;
    }
    // just in case someone typed jointeam hdfsiufhsdfi
    if (!isClientJoiningGame) {
        return Plugin_Continue;
    }
#if defined DEBUG
    LogMessage("Client %s (user id %d) in clientsInGame: %s", clientName, clientUserId, clientInClientList ? "true" : "false");
    LogMessage("clientsInGame length: %d", clientsInGame.GetLength());
    LogMessage("IsServerFull: %s", IsServerFull() ? "true" : "false");
#endif
    if (IsServerFull() && !clientInClientList) {
        ChangeClientTeam(client, TFTeam_Spectator);
        if (putInAutoJoin && !waitQueue.InQueue(client)) {
            waitQueue.Offer(client);
        }
#if defined DEBUG
        LogMessage("Preventing client %s (user id %d) from joining the game", clientName, clientUserId);
#endif
        PrintToChat(client, "%t", putInAutoJoin ? "SPEC_WHEN_FULL_JOIN_SPEC_AUTO" : "SPEC_WHEN_FULL_JOIN_SPEC");
        return Plugin_Handled;
    }
#if defined DEBUG
    LogMessage("Adding client %s (user id %d) to clientsInGame", clientName, clientUserId);
#endif
    if (!clientInClientList) {
        clientsInGame.Offer(client);
    }
    waitQueue.RemoveFromQueue(client);
    return Plugin_Continue;
}

public Action Cmd_AutoJoin(int client, int args) {
    if (client <= 0) {
        return Plugin_Handled;
    }
    if (!IsServerFull()) {
        ReplyToCommand(client, "%t", "SPEC_WHEN_FULL_NOT_FULL");
        return Plugin_Handled;
    }
    if (GetClientTeam(client) != view_as<int>(TFTeam_Spectator)) {
        ReplyToCommand(client, "%t", "SPEC_WHEN_FULL_NOT_SPEC");
        return Plugin_Handled;
    }
    if (waitQueue.InQueue(client)) {
        ReplyToCommand(client, "%t", "SPEC_WHEN_FULL_IN_QUEUE");
        return Plugin_Handled;
    }
    waitQueue.Offer(client);
    ReplyToCommand(client, "%t", "SPEC_WHEN_FULL_AUTOJOIN_PLACE_QUEUE");
    return Plugin_Handled;
}

public Action Cmd_LeaveAutoJoin(int client, int args) {
    if (client <= 0) {
        return Plugin_Handled;
    }
    if (!IsServerFull()) {
        ReplyToCommand(client, "%t", "SPEC_WHEN_FULL_NOT_FULL");
        return Plugin_Handled;
    }
    if (GetClientTeam(client) != view_as<int>(TFTeam_Spectator)) {
        ReplyToCommand(client, "%t", "SPEC_WHEN_FULL_NOT_SPEC");
        return Plugin_Handled;
    }
    if (waitQueue.InQueue(client)) {
        waitQueue.RemoveFromQueue(client);
        ReplyToCommand(client, "%t", "SPEC_WHEN_FULL_AUTOJOIN_REMOVE_QUEUE");
        return Plugin_Handled;
    }
    ReplyToCommand(client, "%t", "SPEC_WHEN_FULL_NOT_IN_QUEUE");
    return Plugin_Handled;
}

public Action Cmd_CheckAutoJoinQueue(int client, int args) {
    if (client <= 0) {
        return Plugin_Handled;
    }
    if (!IsServerFull()) {
        ReplyToCommand(client, "%t", "SPEC_WHEN_FULL_NOT_FULL");
        return Plugin_Handled;
    }
    if (waitQueue.IsEmpty()) {
        ReplyToCommand(client, "%t", "SPEC_WHEN_FULL_AUTOJOIN_EMPTY");
        return Plugin_Handled;
    }
    char title[BASE_STR_LEN];
    Format(title, sizeof(title), "%T", "SPEC_WHEN_FULL_SPEC_QUEUE_MENU_TITLE", client);
    Menu menu = new Menu(Menu_AutoJoinList);
    menu.SetTitle(title);
    menu.Pagination = 10;
    menu.ExitButton = true;
    for (int i = 0; i < waitQueue.GetLength(); i++) {
        int specClientIndex = GetClientOfUserId(waitQueue.clients.Get(i));
        char clientName[MAX_NAME_LENGTH];
        GetClientName(specClientIndex, clientName, sizeof(clientName));
        menu.AddItem(clientName, clientName, ITEMDRAW_DISABLED);
    }
    menu.Display(client, MENU_TIME_FOREVER);
    return Plugin_Handled;
}

#if defined DEBUG
public Action Cmd_CheckClientsInGame(int client, int args) {
    if (client <= 0) {
        return Plugin_Handled;
    }
    Menu menu = new Menu(Menu_AutoJoinList);
    menu.SetTitle("Clients in clientsInGame");
    menu.Pagination = 10;
    menu.ExitButton = true;
    for (int i = 0; i < clientsInGame.GetLength(); i++) {
        int clientUserId = clientsInGame.clients.Get(i);
        int clientIndex = GetClientOfUserId(clientUserId);
        char clientName[MAX_NAME_LENGTH];
        GetClientName(clientIndex, clientName, sizeof(clientName));
        char item[256];
        Format(item, sizeof(item), "%s (user id %d)", clientName, clientUserId);
        menu.AddItem(clientName, item, ITEMDRAW_DISABLED);
    }
    menu.Display(client, MENU_TIME_FOREVER);
    return Plugin_Handled;
}
#endif

public void Menu_AutoJoinList(Menu menu, MenuAction action, int param1, int param2) {
    if (action == MenuAction_End) {
        delete menu;
    }
}

public Action OnAFKKick(int client) {
    if (waitQueue.InQueue(client)) {
        return Plugin_Handled;
    }
    return Plugin_Continue;
}

public void OnAFKSwitch(int client) {
    clientsInGame.RemoveFromQueue(client);
    RunPlayerChangeChecks();
}

void RunPlayerChangeChecks() {
#if defined DEBUG
    LogMessage("RunPlayerChangeChecks()");
#endif
    while (!IsServerFull() && !waitQueue.IsEmpty()) {
        int client = waitQueue.Poll();
        if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client)) {
            continue;
        }
#if defined DEBUG
        int clientUserId = GetClientUserId(client);
        char name[MAX_NAME_LENGTH];
        GetClientName(client, name, sizeof(name));
        LogMessage("Pulling %s (user id %d) from auto join queue", name, clientUserId);
#endif
        if (!clientsInGame.InQueue(client)) {
            clientsInGame.Offer(client);
        }
        FakeClientCommand(client, "jointeam " ... JOIN_TEAM_AUTO);
    }
}

void RebuildClientsInGame() {
    clientsInGame.Clear();
    for (int client = 1; client <= MaxClients; client++) {
        if (!IsClientInGame(client) || IsFakeClient(client)) {
            continue;
        }

        if (IsPlayingTeam(GetClientTeam(client))) {
            clientsInGame.Offer(client);
        }
    }
}

bool IsPlayingTeam(int team) {
    return team == view_as<int>(TFTeam_Red) || team == view_as<int>(TFTeam_Blue);
}

int GetPlayersInGame() {
    return clientsInGame.GetLength();
}

bool IsServerFull() {
    if (cvarMaxPlayersInGame.IntValue == -1) {
        return false;
    }
    return GetPlayersInGame() >= cvarMaxPlayersInGame.IntValue;
}

int GetActualMaxHumanPlayers() {
    return GetMaxHumanPlayers() - GetPlayersToDeduct();
}

int GetHumanCount() {
    return GetClientCount(false) - GetPlayersToDeduct();
}

int GetPlayersToDeduct() {
    int playersToDeduct = 0;
    if (cvarSourceTVEnabled.BoolValue) {
        playersToDeduct++;
    }
    if (cvarReplayEnabled.BoolValue) {
        playersToDeduct++;
    }
    return playersToDeduct;
}
