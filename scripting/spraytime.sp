#include <sourcemod>
#include <sdktools>

#define SAVE_INTERVAL 60.0 // this is how long in seconds the plugin waits before forcing a save for all players

Database g_hDatabase = null;

float g_flSessionTime[MAXPLAYERS + 1];
int   g_iTotalPlaytime[MAXPLAYERS + 1];

int   g_iBypassFlags;
bool  g_bIsSQLite;

static ConVar cvar_timeRequirement;
static ConVar cvar_notify;
static ConVar cvar_bypassFlag;

public Plugin myinfo =
{
	name = "New Player Spray Blocking",
	author = "Jester",
	description = "Blocks sprays until a playtime threshold has been met.",
	version = "1.0.1",
	url = "https://github.com/magisjester"
};

public OnPluginStart()
{
	Database.Connect(OnDatabaseConnected, "spraytime");

	// Hook TF2 spray temp entity
	AddTempEntHook("Player Decal", TE_PlayerDecal);
	
	// autosave to prevent losing time
	CreateTimer(SAVE_INTERVAL, Timer_SavePlaytime, _, TIMER_REPEAT);
	
	cvar_timeRequirement = CreateConVar("st_timerequirement", "3600", "A player must spend this many seconds on the server before they can spray.", _, true, 0.0);
	cvar_notify = CreateConVar("st_notify", "1", "A player will be notified in chat if they can spray or not.", _, true, 0.0, true, 1.0);
	cvar_bypassFlag = CreateConVar("st_bypass_flag", "ab", "Admin flag required to bypass spray restriction.");
	
	HookConVarChange(cvar_bypassFlag, OnBypassFlagChange);
	
    char flags[8];
    cvar_bypassFlag.GetString(flags, sizeof(flags));
    g_iBypassFlags = ReadFlagString(flags);

	AutoExecConfig(true, "spraytime");
}

public void OnDatabaseConnected(Database db, const char[] error, any data)
{
	if (db == null)
	{
		SetFailState("Database connection failed: %s", error);
		return;
	}

	g_hDatabase = db;
	
	char driver[16];
	g_hDatabase.Driver.GetIdentifier(driver, sizeof(driver))
	
	g_bIsSQLite = StrEqual(driver, "sqlite", false); // we need this to make sure we can properly save to sqlite
	
	char query[256];
	FormatEx(query, sizeof(query), "CREATE TABLE IF NOT EXISTS spraytime (auth VARCHAR(64) NOT NULL PRIMARY KEY, time INT NOT NULL DEFAULT 0)");

	g_hDatabase.Query(SQL_GenericCallback, query);
}

public void OnClientPutInServer(int client)
{
	if (IsValidClient(client))
	{
		g_flSessionTime[client] = GetEngineTime();
		g_iTotalPlaytime[client] = 0;
		
		LoadPlaytime(client);
	}
}

public OnClientDisconnect(int client)
{
	if (client < 1 || client > MaxClients || IsFakeClient(client))
		return;

	int session = GetSessionPlaytime(client);
	if (session > 0)
	{
		SavePlaytime(client, session);
	}
	
	g_flSessionTime[client] = 0.0;
	g_iTotalPlaytime[client] = 0;
}

public Action TE_PlayerDecal(const char[] te_name, const int[] players, int numClients, float delay)
{
	//Gets the client that is spraying.
	int client = TE_ReadNum("m_nPlayer");
	
	//Is this even a valid client?
	if(IsValidClient(client))
	{
		// does this client have bypass flags?
		if (GetUserFlagBits(client) & g_iBypassFlags)
			return Plugin_Continue;
		
		int totalTime = g_iTotalPlaytime[client] + GetSessionPlaytime(client);
		int timeRequirement = cvar_timeRequirement.IntValue;
		
		if (totalTime < timeRequirement)
		{
			if (cvar_notify.BoolValue)
			{
				int remaining = timeRequirement - totalTime;

				char timeLeft[32];
				FormatRemainingTime(remaining, timeLeft, sizeof(timeLeft));

				PrintToChat(client,
					"\x04[Spray Time Checker]\x01 You can spray in %s.",
					timeLeft
				);
			}

			return Plugin_Handled;
		}
	}
	
	return Plugin_Continue;
}

// Database Functions

void SavePlaytime(int client, int seconds)
{
	if (g_hDatabase == null)
		return;

	char auth[32];
	GetClientAuthId(client, AuthId_Steam2, auth, sizeof(auth), true);

	char authEscaped[64];
	g_hDatabase.Escape(auth, authEscaped, sizeof(authEscaped));
	
	char query[512];
	if (g_bIsSQLite)
	{
		FormatEx(query, sizeof(query), "INSERT INTO spraytime (auth, time) VALUES ('%s', %d) ON CONFLICT(auth) DO UPDATE SET time = time + %d", authEscaped, seconds, seconds);
	}
	else
	{
		FormatEx(query, sizeof(query), "INSERT INTO spraytime (auth, time) VALUES ('%s', %d) ON DUPLICATE KEY UPDATE time = time + %d", authEscaped, seconds, seconds);
	}

	g_hDatabase.Query(SQL_GenericCallback, query);
}

void LoadPlaytime(int client)
{
	if (g_hDatabase == null)
		return;
	
	char auth[32];
	GetClientAuthId(client, AuthId_Steam2, auth, sizeof(auth), true);

	char authEscaped[64];
	g_hDatabase.Escape(auth, authEscaped, sizeof(authEscaped));

	char query[256];
	FormatEx(query, sizeof(query), "SELECT time FROM spraytime WHERE auth = '%s'", authEscaped);

	g_hDatabase.Query(SQL_LoadPlaytimeCallback, query, GetClientUserId(client));
}

public void SQL_LoadPlaytimeCallback(Database db, DBResultSet results, const char[] error, any userid)
{
	if (error[0] != '\0')
	{
		LogError("SQL error: %s", error);
		return;
	}

	int client = GetClientOfUserId(userid);
	if (!IsValidClient(client))
		return;

	if (results.FetchRow())
	{
		g_iTotalPlaytime[client] = results.FetchInt(0);
	}
}

public void SQL_GenericCallback(Database db, DBResultSet results, const char[] error, any data)
{
	if (error[0] != '\0')
	{
		LogError("SQL error: %s", error);
	}
}

// Utilities

public Action Timer_SavePlaytime(Handle timer)
{
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsValidClient(client))
			continue;

		int session = GetSessionPlaytime(client);
		if (session <= 0)
			continue;

		g_iTotalPlaytime[client] += session;
		g_flSessionTime[client] = GetEngineTime(); // reset counter

		SavePlaytime(client, session);
	}

	return Plugin_Continue;
}

public void OnBypassFlagChange(ConVar convar, const char[] oldValue, const char[] newValue)
{
    char flags[8];
    cvar_bypassFlag.GetString(flags, sizeof(flags));
    g_iBypassFlags = ReadFlagString(flags);
}

void FormatRemainingTime(int seconds, char[] buffer, int maxlen)
{
	if (seconds < 0)
		seconds = 0;

	int minutes = seconds / 60;
	int remaining = seconds % 60;

	if (minutes > 0)
		FormatEx(buffer, maxlen, "%d:%02d", minutes, remaining);
	else
		FormatEx(buffer, maxlen, "0:%02d", remaining);
}

int GetSessionPlaytime(int client)
{
	return RoundToFloor(GetEngineTime() - g_flSessionTime[client]);
}

stock bool IsValidClient(int iClient)
{
	return (iClient >= 1 &&
		iClient <= MaxClients &&
		IsClientConnected(iClient) &&
		IsClientInGame(iClient) &&
		!IsFakeClient(iClient) &&
		!IsClientSourceTV(iClient) &&
		!IsClientReplay(iClient));
}