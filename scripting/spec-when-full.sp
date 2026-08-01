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
#define JOIN_RESERVATION_TIMEOUT 3.0
#define RECONCILE_DELAY 0.5

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
        if (userId > 0 && this.clients.FindValue(userId) == -1) {
            this.clients.Push(userId);
        }
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
int pendingJoinUserIds[MAXPLAYERS + 1];
bool pendingJoinFromQueue[MAXPLAYERS + 1];
Handle playerCheckTimer;

public void OnPluginStart() {
    LoadTranslations("spec-when-full.phrases.txt");

    waitQueue.Init();

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

    AddCommandListener(OnClientJoinTeam, "jointeam");

    HookEvent("player_disconnect", Event_OnPlayerDisconnect);
    HookEvent("player_team", Event_OnPlayerTeam, EventHookMode_Post);

    AutoExecConfig();
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int errMax) {
    MarkNativeAsOptional("DGM_GetGameModeKey");
    MarkNativeAsOptional("DGM_NormalizeMapName");
    MarkNativeAsOptional("DGM_CurrentNormalizedMap");
    MarkNativeAsOptional("DGM_RealPlayerCount");
    return APLRes_Success;
}

public void OnMapStart() {
    PluginStats_OnMapStart();
    ClearAllPendingJoins();
}

public void OnMapEnd() {
    CancelPlayerChangeChecks();
    ClearAllPendingJoins();
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
    CancelPlayerChangeChecks();
    waitQueue.Clear();
    ClearAllPendingJoins();
}

public void OnConfigsExecuted() {
    SetVisibleMaxPlayers();
    SchedulePlayerChangeChecks();
}

public void OnPluginEnd() {
    PluginStats_Shutdown();
    CancelPlayerChangeChecks();
    waitQueue.Deinit();
}

public void OnMaxPlayerCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue) {
    SetVisibleMaxPlayers();
}

public void Event_OnPlayerDisconnect(Event event, const char[] name, bool dontBroadcast) {
    int userid = event.GetInt("userid");
    int client = GetClientOfUserId(userid);
    RemoveUserIdFromWaitQueue(userid, "disconnect");
    ClearPendingJoinByUserId(userid);
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
        bool promotionConfirmed = HasPendingJoin(client) && pendingJoinFromQueue[client];
        RemoveClientFromWaitQueue(client, "joined_team");
        RequestFrame(Frame_ConfirmPendingJoin, userId);
        if (promotionConfirmed) {
            LogPopulationSnapshot("promotion_confirmed", client, oldTeam, newTeam, userId, "team_change");
        }
        SchedulePlayerChangeChecks();
        LogPopulationSnapshot("team_change", client, oldTeam, newTeam);
        return;
    }

    ClearPendingJoin(client);
    if (wasPlaying && newTeam == view_as<int>(TFTeam_Spectator)) {
        RemoveClientFromWaitQueue(client, "voluntary_spectator");
    }
    SchedulePlayerChangeChecks();
    LogPopulationSnapshot("team_change", client, oldTeam, newTeam);
}

void LogPopulationSnapshot(
    const char[] eventName,
    int client = 0,
    int oldTeam = -1,
    int newTeam = -1,
    int userId = 0,
    const char[] reason = "") {
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
    int playersInGame = GetPlayersInGame();
    int pendingJoins = GetPendingJoinCount();
    FormatEx(
        message,
        sizeof(message),
        "event=%s|client=%d|userid=%d|steamid64=%s|old_team=%d|new_team=%d|playercount=%d|players_in_game=%d|pending_joins=%d|effective_players=%d|red=%d|blu=%d|spectator=%d|unassigned=%d|other=%d|queue=%d|max=%d|full=%d|reason=%s",
        eventName,
        client,
        userId,
        steamId64,
        oldTeam,
        newTeam,
        GetHumanCount(),
        playersInGame,
        pendingJoins,
        playersInGame + pendingJoins,
        red,
        blue,
        spectator,
        unassigned,
        other,
        waitQueue.GetLength(),
        cvarMaxPlayersInGame.IntValue,
        IsServerFull() ? 1 : 0,
        reason
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

void SchedulePlayerChangeChecks() {
    if (playerCheckTimer == null) {
        playerCheckTimer = CreateTimer(RECONCILE_DELAY, Timer_RunPlayerCheck, _, TIMER_FLAG_NO_MAPCHANGE);
    }
}

void CancelPlayerChangeChecks() {
    if (playerCheckTimer != null) {
        delete playerCheckTimer;
        playerCheckTimer = null;
    }
}

public Action Timer_RunPlayerCheck(Handle timer) {
    playerCheckTimer = null;
    RunPlayerChangeChecks();
    LogPopulationSnapshot("reconcile_complete", 0, -1, -1, 0, "scheduled_check");
    return Plugin_Stop;
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
    int currentTeam = GetClientTeam(client);
    bool clientWasPlaying = IsPlayingTeam(currentTeam);
    if (!isServerOverloaded) {
#if defined DEBUG
        LogMessage("Server is not overloaded right now");
#endif
        if (isClientJoiningGame && !clientWasPlaying) {
#if defined DEBUG
            LogMessage("Reserving a pending join for %s (user id %d)", clientName, clientUserId);
#endif
            ReservePendingJoin(client, false);
        }
        if (isClientJoiningSpec) {
#if defined DEBUG
            LogMessage("Clearing the pending join for %s (user id %d)", clientName, clientUserId);
#endif
            ClearPendingJoin(client);
            RemoveClientFromWaitQueue(client, "voluntary_spectator");
        }
        if (isClientJoiningSpec) {
            SchedulePlayerChangeChecks();
        } else {
            RunPlayerChangeChecks();
        }
        return Plugin_Continue;
    }
    bool putInAutoJoin = cvarPutSpecInAutoJoin.BoolValue;
    bool clientAlreadyPlaying = clientWasPlaying || HasPendingJoin(client);
    if (isClientJoiningSpec) {
#if defined DEBUG
        LogMessage("Clearing the pending join for %s (user id %d)", clientName, clientUserId);
#endif
        ClearPendingJoin(client);
        RemoveClientFromWaitQueue(client, "voluntary_spectator");
        ChangeClientTeam(client, TFTeam_Spectator);
        PrintToChat(client, "%t", "SPEC_WHEN_FULL_JOIN_SPEC");
        SchedulePlayerChangeChecks();
        return Plugin_Handled;
    }
    // just in case someone typed jointeam hdfsiufhsdfi
    if (!isClientJoiningGame) {
        return Plugin_Continue;
    }
#if defined DEBUG
    LogMessage("Client %s (user id %d) is already playing or reserved: %s", clientName, clientUserId, clientAlreadyPlaying ? "true" : "false");
    LogMessage("Effective players: %d", GetPlayersInGame() + GetPendingJoinCount());
    LogMessage("IsServerFull: %s", IsServerFull() ? "true" : "false");
#endif
    if (IsServerFull() && !clientAlreadyPlaying) {
        ChangeClientTeam(client, TFTeam_Spectator);
        if (putInAutoJoin && !waitQueue.InQueue(client)) {
            AddClientToWaitQueue(client, "full_join_attempt");
        }
#if defined DEBUG
        LogMessage("Preventing client %s (user id %d) from joining the game", clientName, clientUserId);
#endif
        PrintToChat(client, "%t", putInAutoJoin ? "SPEC_WHEN_FULL_JOIN_SPEC_AUTO" : "SPEC_WHEN_FULL_JOIN_SPEC");
        return Plugin_Handled;
    }
#if defined DEBUG
    LogMessage("Reserving a pending join for %s (user id %d)", clientName, clientUserId);
#endif
    if (!clientWasPlaying) {
        ReservePendingJoin(client, false);
    }
    RemoveClientFromWaitQueue(client, "joined_team");
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
    AddClientToWaitQueue(client, "joinqueue_command");
    ReplyToCommand(client, "%t", "SPEC_WHEN_FULL_AUTOJOIN_PLACE_QUEUE");
    return Plugin_Handled;
}

public Action Cmd_LeaveAutoJoin(int client, int args) {
    if (client <= 0) {
        return Plugin_Handled;
    }
    if (GetClientTeam(client) != view_as<int>(TFTeam_Spectator)) {
        ReplyToCommand(client, "%t", "SPEC_WHEN_FULL_NOT_SPEC");
        return Plugin_Handled;
    }
    if (waitQueue.InQueue(client)) {
        RemoveClientFromWaitQueue(client, "leavequeue_command");
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
    PruneWaitQueue();
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
        if (!IsQueuedSpectator(specClientIndex)) {
            continue;
        }
        char clientName[MAX_NAME_LENGTH];
        GetClientName(specClientIndex, clientName, sizeof(clientName));
        menu.AddItem(clientName, clientName, ITEMDRAW_DISABLED);
    }
    menu.Display(client, MENU_TIME_FOREVER);
    return Plugin_Handled;
}

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
    ClearPendingJoin(client);
    SchedulePlayerChangeChecks();
}

void RunPlayerChangeChecks() {
#if defined DEBUG
    LogMessage("RunPlayerChangeChecks()");
#endif
    PruneWaitQueue();
    while (!IsServerFull() && !waitQueue.IsEmpty()) {
        int client = waitQueue.Poll();
        if (!IsQueuedSpectator(client)) {
            continue;
        }
        LogPopulationSnapshot("queue_removed", client, -1, -1, GetClientUserId(client), "promotion");
#if defined DEBUG
        int clientUserId = GetClientUserId(client);
        char name[MAX_NAME_LENGTH];
        GetClientName(client, name, sizeof(name));
        LogMessage("Pulling %s (user id %d) from auto join queue", name, clientUserId);
#endif
        ReservePendingJoin(client, true);
        LogPopulationSnapshot("promotion_requested", client, -1, -1, GetClientUserId(client), "queue_head");
        FakeClientCommand(client, "jointeam " ... JOIN_TEAM_AUTO);
        SchedulePlayerChangeChecks();
        break;
    }
}

bool IsQueuedSpectator(int client) {
    return client > 0 && IsClientInGame(client) && !IsFakeClient(client)
        && GetClientTeam(client) == view_as<int>(TFTeam_Spectator);
}

void PruneWaitQueue() {
    for (int i = waitQueue.GetLength() - 1; i >= 0; i--) {
        int userId = waitQueue.clients.Get(i);
        int client = GetClientOfUserId(userId);
        if (!IsQueuedSpectator(client)) {
            waitQueue.clients.Erase(i);
            LogPopulationSnapshot("queue_removed", client, -1, -1, userId, "stale_entry");
        }
    }
}

bool AddClientToWaitQueue(int client, const char[] reason) {
    if (!IsQueuedSpectator(client) || waitQueue.InQueue(client)) {
        return false;
    }
    waitQueue.Offer(client);
    LogPopulationSnapshot("queue_added", client, -1, -1, GetClientUserId(client), reason);
    return true;
}

bool RemoveClientFromWaitQueue(int client, const char[] reason) {
    if (client <= 0 || !waitQueue.RemoveFromQueue(client)) {
        return false;
    }
    LogPopulationSnapshot("queue_removed", client, -1, -1, GetClientUserId(client), reason);
    return true;
}

bool RemoveUserIdFromWaitQueue(int userId, const char[] reason) {
    if (!waitQueue.RemoveUserIdFromQueue(userId)) {
        return false;
    }
    int client = GetClientOfUserId(userId);
    LogPopulationSnapshot("queue_removed", client, -1, -1, userId, reason);
    return true;
}

int CountPlayingHumansLocally() {
    int count = 0;
    for (int client = 1; client <= MaxClients; client++) {
        if (!IsClientInGame(client) || IsFakeClient(client)) {
            continue;
        }

        if (IsPlayingTeam(GetClientTeam(client))) {
            count++;
        }
    }
    return count;
}

bool IsPlayingTeam(int team) {
    return team == view_as<int>(TFTeam_Red) || team == view_as<int>(TFTeam_Blue);
}

int GetPlayersInGame() {
    if (GetFeatureStatus(FeatureType_Native, "DGM_RealPlayerCount") == FeatureStatus_Available) {
        return DGM_RealPlayerCount();
    }
    return CountPlayingHumansLocally();
}

bool IsServerFull() {
    if (cvarMaxPlayersInGame.IntValue == -1) {
        return false;
    }
    return GetPlayersInGame() + GetPendingJoinCount() >= cvarMaxPlayersInGame.IntValue;
}

bool HasPendingJoin(int client) {
    return client > 0 && client <= MaxClients && IsClientConnected(client)
        && pendingJoinUserIds[client] == GetClientUserId(client);
}

void ReservePendingJoin(int client, bool fromQueue) {
    if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client) || IsPlayingTeam(GetClientTeam(client))) {
        return;
    }

    if (HasPendingJoin(client)) {
        pendingJoinFromQueue[client] = pendingJoinFromQueue[client] || fromQueue;
        return;
    }

    int userId = GetClientUserId(client);
    pendingJoinUserIds[client] = userId;
    pendingJoinFromQueue[client] = fromQueue;
    CreateTimer(JOIN_RESERVATION_TIMEOUT, Timer_ExpirePendingJoin, userId, TIMER_FLAG_NO_MAPCHANGE);
}

void ClearPendingJoin(int client) {
    if (client <= 0 || client > MaxClients) {
        return;
    }
    pendingJoinUserIds[client] = 0;
    pendingJoinFromQueue[client] = false;
}

void ClearPendingJoinByUserId(int userId) {
    int client = GetClientOfUserId(userId);
    if (client > 0) {
        ClearPendingJoin(client);
        return;
    }

    for (int i = 1; i <= MaxClients; i++) {
        if (pendingJoinUserIds[i] == userId) {
            ClearPendingJoin(i);
            return;
        }
    }
}

void ClearAllPendingJoins() {
    for (int client = 1; client <= MaxClients; client++) {
        ClearPendingJoin(client);
    }
}

int GetPendingJoinCount() {
    int count = 0;
    for (int client = 1; client <= MaxClients; client++) {
        if (!HasPendingJoin(client)) {
            continue;
        }
        if (!IsClientInGame(client) || IsPlayingTeam(GetClientTeam(client))) {
            ClearPendingJoin(client);
            continue;
        }
        count++;
    }
    return count;
}

public void Frame_ConfirmPendingJoin(any userId) {
    int client = GetClientOfUserId(userId);
    if (client > 0 && IsClientInGame(client) && IsPlayingTeam(GetClientTeam(client))) {
        ClearPendingJoin(client);
        SchedulePlayerChangeChecks();
    }
}

public Action Timer_ExpirePendingJoin(Handle timer, any userId) {
    int client = GetClientOfUserId(userId);
    if (client > 0 && pendingJoinUserIds[client] == userId) {
        bool requeue = pendingJoinFromQueue[client] && IsQueuedSpectator(client);
        LogPopulationSnapshot("promotion_failed", client, -1, -1, userId, "confirmation_timeout");
        ClearPendingJoin(client);
        if (requeue) {
            AddClientToWaitQueue(client, "promotion_retry");
        }
        SchedulePlayerChangeChecks();
    }
    return Plugin_Stop;
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
