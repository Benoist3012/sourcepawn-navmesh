#include <sourcemod>
#include <sdktools>
#include <navmesh>

#define PLUGIN_VERSION "1.0.0"

public Plugin:myinfo = 
{
    name = "SP-Readable Navigation Mesh",
    author	= "KitRifty (code based from pimpinjuice)",
    description	= "Heavily based off of pimpinjuice's .cpp code for War3Source, this analyzes the map's .nav file and creates the mesh based off the info.",
    version = PLUGIN_VERSION,
    url = ""
}

#define NAV_MAGIC_NUMBER 0xFEEDFACE

#define UNSIGNED_INT_BYTE_SIZE 4
#define UNSIGNED_CHAR_BYTE_SIZE 1
#define UNSIGNED_SHORT_BYTE_SIZE 2
#define FLOAT_BYTE_SIZE 4

new Handle:g_hNavMesh;
new bool:g_bNavMeshBuilt = false;

// For A* pathfinding.
new g_iNavMeshAreaOpenListIndex = -1;
new g_iNavMeshAreaOpenListTailIndex = -1;
new g_iNavMeshAreaMasterMarker = 0;


public APLRes:AskPluginLoad2(Handle:myself, bool:late, String:error[], err_max)
{
	RegPluginLibrary("navmesh");
	
	CreateNative("NavMesh_Exists", Native_NavMeshExists);
	CreateNative("NavMesh_GetMagicNumber", Native_NavMeshGetMagicNumber);
	CreateNative("NavMesh_GetVersion", Native_NavMeshGetVersion);
	CreateNative("NavMesh_GetSubVersion", Native_NavMeshGetSubVersion);
	CreateNative("NavMesh_GetSaveBSPSize", Native_NavMeshGetSaveBSPSize);
	CreateNative("NavMesh_IsAnalyzed", Native_NavMeshIsAnalyzed);
	CreateNative("NavMesh_GetPlaces", Native_NavMeshGetPlaces);
	CreateNative("NavMesh_GetAreas", Native_NavMeshGetAreas);
	CreateNative("NavMesh_GetLadders", Native_NavMeshGetLadders);
	
	CreateNative("NavMesh_BuildPath", Native_NavMeshBuildPath);
	
	CreateNative("NavMesh_GetArea", Native_NavMeshGetArea);
	CreateNative("NavMesh_GetNearestArea", Native_NavMeshGetNearestArea);
	
	CreateNative("NavMeshArea_GetMasterMarker", Native_NavMeshAreaGetMasterMarker);
	CreateNative("NavMeshArea_ChangeMasterMarker", Native_NavMeshAreaChangeMasterMarker);
	
	CreateNative("NavMeshArea_GetFlags", Native_NavMeshAreaGetFlags);
	CreateNative("NavMeshArea_GetCenter", Native_NavMeshAreaGetCenter);
	CreateNative("NavMeshArea_GetAdjacentList", Native_NavMeshAreaGetAdjacentList);
	CreateNative("NavMeshArea_GetLadderList", Native_NavMeshAreaGetLadderList);
	CreateNative("NavMeshArea_GetTotalCost", Native_NavMeshAreaGetTotalCost);
	CreateNative("NavMeshArea_GetParent", Native_NavMeshAreaGetParent);
	CreateNative("NavMeshArea_GetParentHow", Native_NavMeshAreaGetParentHow);
	CreateNative("NavMeshArea_SetParent", Native_NavMeshAreaSetParent);
	CreateNative("NavMeshArea_SetParentHow", Native_NavMeshAreaSetParentHow);
	CreateNative("NavMeshArea_GetCostSoFar", Native_NavMeshAreaGetCostSoFar);
	CreateNative("NavMeshArea_GetExtentLow", Native_NavMeshAreaGetExtentLow);
	CreateNative("NavMeshArea_GetExtentHigh", Native_NavMeshAreaGetExtentHigh);
	CreateNative("NavMeshArea_IsOverlappingPoint", Native_NavMeshAreaIsOverlappingPoint);
	CreateNative("NavMeshArea_IsOverlappingArea", Native_NavMeshAreaIsOverlappingArea);
	CreateNative("NavMeshArea_GetNECornerZ", Native_NavMeshAreaGetNECornerZ);
	CreateNative("NavMeshArea_GetSWCornerZ", Native_NavMeshAreaGetSWCornerZ);
	CreateNative("NavMeshArea_GetZ", Native_NavMeshAreaGetZ);
	CreateNative("NavMeshArea_GetZFromXAndY", Native_NavMeshAreaGetZFromXAndY);
	CreateNative("NavMeshArea_Contains", Native_NavMeshAreaContains);
	CreateNative("NavMeshArea_ComputePortal", Native_NavMeshAreaComputePortal);
	CreateNative("NavMeshArea_ComputeClosestPointInPortal", Native_NavMeshAreaComputeClosestPointInPortal);
	CreateNative("NavMeshArea_ComputeDirection", Native_NavMeshAreaComputeDirection);
	CreateNative("NavMeshArea_GetLightIntensity", Native_NavMeshAreaGetLightIntensity);
	
	CreateNative("NavMeshLadder_GetLength", Native_NavMeshLadderGetLength);
}

public OnPluginStart()
{
	g_hNavMesh = CreateArray(NavMesh_MaxStats);
	
	HookEvent("nav_blocked", Event_NavAreaBlocked);
}

public OnMapStart()
{
	NavMeshDestroy();

	decl String:sMap[256];
	GetCurrentMap(sMap, sizeof(sMap));
	
	g_bNavMeshBuilt = NavMeshLoad(sMap);
}

public Event_NavAreaBlocked(Handle:event, const String:name[], bool:dB)
{
	if (!g_bNavMeshBuilt) return;

	new Handle:hAreas = Handle:GetArrayCell(g_hNavMesh, 0, NavMesh_Areas);
	if (hAreas != INVALID_HANDLE)
	{
		new iAreaID = GetEventInt(event, "area");
		new iAreaIndex = FindValueInArray(hAreas, iAreaID);
		if (iAreaIndex != -1)
		{
			new bool:bBlocked = bool:GetEventInt(event, "blocked");
			SetArrayCell(hAreas, iAreaIndex, bBlocked, NavMeshArea_Blocked);
		}
	}
}

bool:NavMeshBuildPath(iStartAreaIndex,
	iGoalAreaIndex,
	const Float:flGoalPos[3],
	Handle:hCostFunctionPlugin,
	Function:iCostFunction,
	any:iCostData=INVALID_HANDLE,
	&iClosestAreaIndex=-1,
	Float:flMaxPathLength=0.0)
{
	if (!g_bNavMeshBuilt) 
	{
		LogError("Could not build path because the nav mesh does not exist!");
		return false;
	}
	
	new Handle:hAreas = Handle:GetArrayCell(g_hNavMesh, 0, NavMesh_Areas);
	if (hAreas == INVALID_HANDLE)
	{
		LogError("Could not build path because the nav mesh does not have any areas!");
		return false;
	}
	
	if (iClosestAreaIndex != -1) 
	{
		iClosestAreaIndex = iStartAreaIndex;
	}
	
	if (iStartAreaIndex == -1)
	{
		LogError("Could not build path because the starting area does not exist!");
		return false;
	}
	
	SetArrayCell(hAreas, iStartAreaIndex, -1, NavMeshArea_Parent);
	SetArrayCell(hAreas, iStartAreaIndex, NUM_TRAVERSE_TYPES, NavMeshArea_ParentHow);
	
	if (iGoalAreaIndex == -1)
	{
		LogError("Could not build path from area %d to area %d because the goal area does not exist!");
		return false;
	}
	
	if (iStartAreaIndex == iGoalAreaIndex) return true;
	
	// Start the search.
	NavMeshAreaClearSearchLists();
	
	// Compute estimate of path length.
	decl Float:flStartAreaCenter[3];
	NavMeshAreaGetCenter(iStartAreaIndex, flStartAreaCenter);
	
	new iStartTotalCost = RoundFloat(GetVectorDistance(flStartAreaCenter, flGoalPos));
	SetArrayCell(hAreas, iStartAreaIndex, iStartTotalCost, NavMeshArea_TotalCost);
	
	new iInitCost;
	
	Call_StartFunction(hCostFunctionPlugin, iCostFunction);
	Call_PushCell(iStartAreaIndex);
	Call_PushCell(-1);
	Call_PushCell(-1);
	Call_PushCell(iCostData);
	Call_Finish(iInitCost);
	
	if (iInitCost < 0) return false;
	
	SetArrayCell(hAreas, iStartAreaIndex, 0, NavMeshArea_CostSoFar);
	SetArrayCell(hAreas, iStartAreaIndex, 0.0, NavMeshArea_PathLengthSoFar);
	NavMeshAreaAddToOpenList(iStartAreaIndex);
	
	new iClosestAreaDist = iStartTotalCost;
	
	new Handle:hLadders = Handle:GetArrayCell(g_hNavMesh, 0, NavMesh_Ladders);
	
	new bool:bHaveMaxPathLength = bool:(flMaxPathLength != 0.0);
	
	// Perform A* search.
	while (!NavMeshAreaIsOpenListEmpty())
	{
		new iAreaIndex = NavMeshAreaPopOpenList();
		
		if (bool:GetArrayCell(hAreas, iAreaIndex, NavMeshArea_Blocked)) 
		{
			// Don't consider blocked areas.
			continue;
		}
		
		if (iAreaIndex == iGoalAreaIndex ||
			(iGoalAreaIndex == -1 && NavMeshAreaContains(iAreaIndex, flGoalPos)))
		{
			if (iClosestAreaIndex != -1)
			{
				iClosestAreaIndex = iGoalAreaIndex;
			}
			
			return true;
		}
		
		// No support for elevator areas yet.
		static SEARCH_FLOOR = 0, SEARCH_LADDERS = 1;
		
		new iSearchWhere = SEARCH_FLOOR;
		new iSearchDir = NAV_DIR_NORTH;
		
		new Handle:hFloorList = NavMeshAreaGetAdjacentList(iAreaIndex, iSearchDir);
		
		new bool:bLadderUp = true;
		new Handle:hLadderList = INVALID_HANDLE;
		new iLadderTopDir = 0;
		
		for (;;)
		{
			new iNewAreaIndex = -1;
			new iNavTraverseHow = 0;
			new iLadderIndex = -1;
			
			if (iSearchWhere == SEARCH_FLOOR)
			{
				if (hFloorList == INVALID_HANDLE || IsStackEmpty(hFloorList))
				{
					iSearchDir++;
					if (hFloorList != INVALID_HANDLE) CloseHandle(hFloorList);
					
					if (iSearchDir == NAV_DIR_COUNT)
					{
						iSearchWhere = SEARCH_LADDERS;
						
						hLadderList = NavMeshAreaGetLadderList(iAreaIndex, NAV_LADDER_DIR_UP);
						iLadderTopDir = 0;
					}
					else
					{
						hFloorList = NavMeshAreaGetAdjacentList(iAreaIndex, iSearchDir);
					}
					
					continue;
				}
				
				PopStackCell(hFloorList, iNewAreaIndex);
				iNavTraverseHow = iSearchDir;
			}
			else if (iSearchWhere == SEARCH_LADDERS)
			{
				if (hLadderList == INVALID_HANDLE || IsStackEmpty(hLadderList))
				{
					if (hLadderList != INVALID_HANDLE) CloseHandle(hLadderList);
					
					if (!bLadderUp)
					{
						iLadderIndex = -1;
						break;
					}
					else
					{
						bLadderUp = false;
						hLadderList = NavMeshAreaGetLadderList(iAreaIndex, NAV_LADDER_DIR_DOWN);
					}
					
					continue;
				}
				
				PopStackCell(hLadderList, iLadderIndex);
				
				if (bLadderUp)
				{
					switch (iLadderTopDir)
					{
						case 0:
						{
							iNewAreaIndex = GetArrayCell(hLadders, iLadderIndex, NavMeshLadder_TopForwardAreaIndex);
						}
						case 1:
						{
							iNewAreaIndex = GetArrayCell(hLadders, iLadderIndex, NavMeshLadder_TopLeftAreaIndex);
						}
						case 2:
						{
							iNewAreaIndex = GetArrayCell(hLadders, iLadderIndex, NavMeshLadder_TopRightAreaIndex);
						}
						default:
						{
							iLadderTopDir = 0;
							continue;
						}
					}
					
					iNavTraverseHow = GO_LADDER_UP;
					iLadderTopDir++;
				}
				else
				{
					iNewAreaIndex = GetArrayCell(hLadders, iLadderIndex, NavMeshLadder_BottomAreaIndex);
					iNavTraverseHow = GO_LADDER_DOWN;
				}
				
				if (iNewAreaIndex == -1) continue;
			}
			
			if (GetArrayCell(hAreas, iAreaIndex, NavMeshArea_Parent) == iNewAreaIndex) 
			{
				// Don't backtrack.
				continue;
			}
			
			if (iNewAreaIndex == iAreaIndex)
			{
				continue;
			}
			
			if (bool:GetArrayCell(hAreas, iNewAreaIndex, NavMeshArea_Blocked)) 
			{
				// Don't consider blocked areas.
				continue;
			}
			
			new iNewCostSoFar;
			
			Call_StartFunction(hCostFunctionPlugin, iCostFunction);
			Call_PushCell(iNewAreaIndex);
			Call_PushCell(iAreaIndex);
			Call_PushCell(iLadderIndex);
			Call_Finish(iNewCostSoFar);
			
			if (iNewCostSoFar < 0) continue;
			
			decl Float:flNewAreaCenter[3];
			NavMeshAreaGetCenter(iNewAreaIndex, flNewAreaCenter);
			
			if (bHaveMaxPathLength)
			{
				decl Float:flAreaCenter[3];
				NavMeshAreaGetCenter(iAreaIndex, flAreaCenter);
				
				new Float:flDeltaLength = GetVectorDistance(flNewAreaCenter, flAreaCenter);
				new Float:flNewLengthSoFar = Float:GetArrayCell(hAreas, iAreaIndex, NavMeshArea_PathLengthSoFar) + flDeltaLength;
				if (flNewLengthSoFar > flMaxPathLength)
				{
					continue;
				}
				
				SetArrayCell(hAreas, iNewAreaIndex, flNewLengthSoFar, NavMeshArea_PathLengthSoFar);
			}
			
			if ((NavMeshAreaIsOpen(iNewAreaIndex) || NavMeshAreaIsClosed(iNewAreaIndex)) &&
				GetArrayCell(hAreas, iNewAreaIndex, NavMeshArea_CostSoFar) <= iNewCostSoFar)
			{
				continue;
			}
			else
			{
				new iNewCostRemaining = RoundFloat(GetVectorDistance(flNewAreaCenter, flGoalPos));
				
				if (iClosestAreaIndex != -1 && iNewCostRemaining < iClosestAreaDist)
				{
					iClosestAreaIndex = iNewAreaIndex;
					iClosestAreaDist = iNewCostRemaining;
				}
				
				SetArrayCell(hAreas, iNewAreaIndex, iNewCostSoFar, NavMeshArea_CostSoFar);
				SetArrayCell(hAreas, iNewAreaIndex, iNewCostSoFar + iNewCostRemaining, NavMeshArea_TotalCost);
				
				/*
				if (NavMeshAreaIsClosed(iNewAreaIndex)) 
				{
					NavMeshAreaRemoveFromClosedList(iNewAreaIndex);
				}
				*/
				
				if (NavMeshAreaIsOpen(iNewAreaIndex))
				{
					NavMeshAreaUpdateOnOpenList(iNewAreaIndex);
				}
				else
				{
					NavMeshAreaAddToOpenList(iNewAreaIndex);
				}
				
				SetArrayCell(hAreas, iNewAreaIndex, iAreaIndex, NavMeshArea_Parent);
				SetArrayCell(hAreas, iNewAreaIndex, iNavTraverseHow, NavMeshArea_ParentHow);
			}
		}
		
		NavMeshAreaAddToClosedList(iAreaIndex);
	}
	
	return false;
}

NavMeshAreaClearSearchLists()
{
	g_iNavMeshAreaMasterMarker++;
	g_iNavMeshAreaOpenListIndex = -1;
	g_iNavMeshAreaOpenListTailIndex = -1;
}

bool:NavMeshAreaIsMarked(iAreaIndex)
{
	new Handle:hAreas = Handle:GetArrayCell(g_hNavMesh, 0, NavMesh_Areas);
	return bool:(GetArrayCell(hAreas, iAreaIndex, NavMeshArea_Marker) == g_iNavMeshAreaMasterMarker);
}

NavMeshAreaMark(iAreaIndex)
{
	new Handle:hAreas = Handle:GetArrayCell(g_hNavMesh, 0, NavMesh_Areas);
	SetArrayCell(hAreas, iAreaIndex, g_iNavMeshAreaMasterMarker, NavMeshArea_Marker);
}

bool:NavMeshAreaIsOpen(iAreaIndex)
{
	new Handle:hAreas = Handle:GetArrayCell(g_hNavMesh, 0, NavMesh_Areas);
	return bool:(GetArrayCell(hAreas, iAreaIndex, NavMeshArea_OpenMarker) == g_iNavMeshAreaMasterMarker);
}

bool:NavMeshAreaIsOpenListEmpty()
{
	return bool:(g_iNavMeshAreaOpenListIndex == -1);
}

NavMeshAreaAddToOpenList(iAreaIndex)
{
	if (NavMeshAreaIsOpen(iAreaIndex)) return;

	new Handle:hAreas = Handle:GetArrayCell(g_hNavMesh, 0, NavMesh_Areas);
	
	SetArrayCell(hAreas, iAreaIndex, g_iNavMeshAreaMasterMarker, NavMeshArea_OpenMarker);
	
	if (g_iNavMeshAreaOpenListIndex == -1)
	{
		g_iNavMeshAreaOpenListIndex = iAreaIndex;
		g_iNavMeshAreaOpenListTailIndex = iAreaIndex;
		SetArrayCell(hAreas, iAreaIndex, -1, NavMeshArea_PrevOpenIndex);
		SetArrayCell(hAreas, iAreaIndex, -1, NavMeshArea_NextOpenIndex);
		return;
	}
	
	new iTotalCost = GetArrayCell(hAreas, iAreaIndex, NavMeshArea_TotalCost);
	
	new iTempAreaIndex = -1, iLastAreaIndex = -1;
	for (iTempAreaIndex = g_iNavMeshAreaOpenListIndex; iTempAreaIndex != -1; iTempAreaIndex = GetArrayCell(hAreas, iTempAreaIndex, NavMeshArea_NextOpenIndex))
	{
		if (iTotalCost < GetArrayCell(hAreas, iTempAreaIndex, NavMeshArea_TotalCost)) break;
		iLastAreaIndex = iTempAreaIndex;
	}
	
	if (iTempAreaIndex != -1)
	{
		new iPrevOpenIndex = GetArrayCell(hAreas, iTempAreaIndex, NavMeshArea_PrevOpenIndex);
		SetArrayCell(hAreas, iAreaIndex, iPrevOpenIndex, NavMeshArea_PrevOpenIndex);
		
		if (iPrevOpenIndex != -1)
		{
			SetArrayCell(hAreas, iPrevOpenIndex, iAreaIndex, NavMeshArea_NextOpenIndex);
		}
		else
		{
			g_iNavMeshAreaOpenListIndex = iAreaIndex;
		}
		
		SetArrayCell(hAreas, iAreaIndex, iTempAreaIndex, NavMeshArea_NextOpenIndex);
		SetArrayCell(hAreas, iTempAreaIndex, iAreaIndex, NavMeshArea_PrevOpenIndex);
	}
	else
	{
		SetArrayCell(hAreas, iLastAreaIndex, iAreaIndex, NavMeshArea_NextOpenIndex);
		SetArrayCell(hAreas, iAreaIndex, iLastAreaIndex, NavMeshArea_PrevOpenIndex);
		
		SetArrayCell(hAreas, iAreaIndex, -1, NavMeshArea_NextOpenIndex);
		
		g_iNavMeshAreaOpenListTailIndex = iAreaIndex;
	}
}

/*
static NavMeshAreaAddToOpenListTail(iAreaIndex)
{
	if (NavMeshAreaIsOpen(iAreaIndex)) return;
	
	SetArrayCell(hAreas, iAreaIndex, g_iNavMeshAreaMasterMarker, NavMeshArea_OpenMarker);
	
	if (g_iNavMeshAreaOpenListIndex == -1)
	{
		g_iNavMeshAreaOpenListIndex = iAreaIndex;
		g_iNavMeshAreaOpenListTailIndex = iAreaIndex;
		SetArrayCell(hAreas, iAreaIndex, -1, NavMeshArea_PrevOpenIndex);
		SetArrayCell(hAreas, iAreaIndex, -1, NavMeshArea_NextOpenIndex);
		return;
	}
	
	SetArrayCell(hAreas, g_iNavMeshAreaOpenListTailIndex, iAreaIndex, NavMeshArea_NextOpenIndex);
	
	SetArrayCell(hAreas, iAreaIndex, g_iNavMeshAreaOpenListTailIndex, NavMeshArea_PrevOpenIndex);
	SetArrayCell(hAreas, iAreaIndex, -1, NavMeshArea_NextOpenIndex);
	
	g_iNavMeshAreaOpenListTailIndex = iAreaIndex;
}
*/

NavMeshAreaUpdateOnOpenList(iAreaIndex)
{
	new Handle:hAreas = Handle:GetArrayCell(g_hNavMesh, 0, NavMesh_Areas);
	
	new iTotalCost = GetArrayCell(hAreas, iAreaIndex, NavMeshArea_TotalCost);
	
	new iPrevIndex = -1;
	
	while ((iPrevIndex = GetArrayCell(hAreas, iAreaIndex, NavMeshArea_PrevOpenIndex)) != -1 &&
		iTotalCost < (GetArrayCell(hAreas, iPrevIndex, NavMeshArea_TotalCost)))
	{
		new iOtherIndex = iPrevIndex;
		new iBeforeIndex = GetArrayCell(hAreas, iPrevIndex, NavMeshArea_PrevOpenIndex);
		new iAfterIndex = GetArrayCell(hAreas, iAreaIndex, NavMeshArea_NextOpenIndex);
	
		SetArrayCell(hAreas, iAreaIndex, iPrevIndex, NavMeshArea_NextOpenIndex);
		SetArrayCell(hAreas, iAreaIndex, iBeforeIndex, NavMeshArea_PrevOpenIndex);
		
		SetArrayCell(hAreas, iOtherIndex, iAreaIndex, NavMeshArea_PrevOpenIndex);
		SetArrayCell(hAreas, iOtherIndex, iAfterIndex, NavMeshArea_NextOpenIndex);
		
		if (iBeforeIndex != -1)
		{
			SetArrayCell(hAreas, iBeforeIndex, iAreaIndex, NavMeshArea_NextOpenIndex);
		}
		else
		{
			g_iNavMeshAreaOpenListIndex = iAreaIndex;
		}
		
		if (iAfterIndex != -1)
		{
			SetArrayCell(hAreas, iAfterIndex, iOtherIndex, NavMeshArea_PrevOpenIndex);
		}
		else
		{
			g_iNavMeshAreaOpenListTailIndex = iAreaIndex;
		}
	}
}

NavMeshAreaRemoveFromOpenList(iAreaIndex)
{
	new Handle:hAreas = Handle:GetArrayCell(g_hNavMesh, 0, NavMesh_Areas);
	
	if (GetArrayCell(hAreas, iAreaIndex, NavMeshArea_OpenMarker) == 0) return;
	
	new iPrevOpenIndex = GetArrayCell(hAreas, iAreaIndex, NavMeshArea_PrevOpenIndex);
	new iNextOpenIndex = GetArrayCell(hAreas, iAreaIndex, NavMeshArea_NextOpenIndex);
	
	if (iPrevOpenIndex != -1)
	{
		SetArrayCell(hAreas, iPrevOpenIndex, iNextOpenIndex, NavMeshArea_NextOpenIndex);
	}
	else
	{
		g_iNavMeshAreaOpenListIndex = iNextOpenIndex;
	}
	
	if (iNextOpenIndex != -1)
	{
		SetArrayCell(hAreas, iNextOpenIndex, iPrevOpenIndex, NavMeshArea_PrevOpenIndex);
	}
	else
	{
		g_iNavMeshAreaOpenListTailIndex = iPrevOpenIndex;
	}
	
	SetArrayCell(hAreas, iAreaIndex, 0, NavMeshArea_OpenMarker);
}

NavMeshAreaPopOpenList()
{
	if (g_iNavMeshAreaOpenListIndex != -1)
	{
		new Handle:hAreas = Handle:GetArrayCell(g_hNavMesh, 0, NavMesh_Areas);
	
		new iOpenListIndex = g_iNavMeshAreaOpenListIndex;
	
		NavMeshAreaRemoveFromOpenList(iOpenListIndex);
		SetArrayCell(hAreas, iOpenListIndex, -1, NavMeshArea_PrevOpenIndex);
		SetArrayCell(hAreas, iOpenListIndex, -1, NavMeshArea_NextOpenIndex);
		
		return iOpenListIndex;
	}
	
	return -1;
}

bool:NavMeshAreaIsClosed(iAreaIndex)
{
	if (NavMeshAreaIsMarked(iAreaIndex) && !NavMeshAreaIsOpen(iAreaIndex)) return true;
	return false;
}

NavMeshAreaAddToClosedList(iAreaIndex)
{
	NavMeshAreaMark(iAreaIndex);
}

/*
static NavMeshAreaRemoveFromClosedList(iAreaIndex)
{
}
*/

bool:NavMeshLoad(const String:sMapName[])
{
	decl String:sNavFilePath[PLATFORM_MAX_PATH];
	Format(sNavFilePath, sizeof(sNavFilePath), "maps\\%s.nav", sMapName);
	
	new Handle:hFile = OpenFile(sNavFilePath, "rb");
	if (hFile == INVALID_HANDLE)
	{
		LogError("Unable to find navigation mesh: %s", sNavFilePath);
		return false;
	}
	
	// Get magic number.
	new iNavMagicNumber;
	new iElementsRead = ReadFileCell(hFile, iNavMagicNumber, UNSIGNED_INT_BYTE_SIZE);
	
	if (iElementsRead != 1)
	{
		CloseHandle(hFile);
		LogError("Error reading magic number value from navigation mesh: %s", sNavFilePath);
		return false;
	}
	
	if (iNavMagicNumber != NAV_MAGIC_NUMBER)
	{
		CloseHandle(hFile);
		LogError("Invalid magic number value from navigation mesh: %s [%p]", sNavFilePath, iNavMagicNumber);
		return false;
	}
	
	// Get the version.
	new iNavVersion;
	iElementsRead = ReadFileCell(hFile, iNavVersion, UNSIGNED_INT_BYTE_SIZE);
	
	if (iElementsRead != 1)
	{
		CloseHandle(hFile);
		LogError("Error reading version number from navigation mesh: %s", sNavFilePath);
		return false;
	}
	
	if (iNavVersion < 6 || iNavVersion > 16)
	{
		CloseHandle(hFile);
		LogError("Invalid version number value from navigation mesh: %s [%d]", sNavFilePath, iNavVersion);
		return false;
	}
	
	// Get the sub version, if supported.
	new iNavSubVersion;
	if (iNavVersion >= 10)
	{
		ReadFileCell(hFile, iNavSubVersion, UNSIGNED_INT_BYTE_SIZE);
	}
	
	// Get the save bsp size.
	new iNavSaveBspSize;
	if (iNavVersion >= 4)
	{
		ReadFileCell(hFile, iNavSaveBspSize, UNSIGNED_INT_BYTE_SIZE);
	}
	
	// Check if the nav mesh was analyzed.
	new iNavMeshAnalyzed;
	if (iNavVersion >= 14)
	{
		ReadFileCell(hFile, iNavMeshAnalyzed, UNSIGNED_CHAR_BYTE_SIZE);
		LogMessage("Is mesh analyzed: %d", iNavMeshAnalyzed);
	}
	
	LogMessage("Nav version: %d; SubVersion: %d (v10+); BSPSize: %d; MagicNumber: %d", iNavVersion, iNavSubVersion, iNavSaveBspSize, iNavMagicNumber);
	
	new iPlaceCount;
	ReadFileCell(hFile, iPlaceCount, UNSIGNED_SHORT_BYTE_SIZE);
	LogMessage("Place count: %d", iPlaceCount);
	
	// Parse through places.
	// TF2 doesn't use places, but CS:S does.
	new Handle:hPlaces = CreateArray(256);
	
	for (new iPlaceIndex = 0; iPlaceIndex < iPlaceCount; iPlaceIndex++) 
	{
		new iPlaceSize;
		ReadFileCell(hFile, iPlaceSize, UNSIGNED_SHORT_BYTE_SIZE);
		
		new String:sPlaceName[256];
		ReadFileString(hFile, sPlaceName, sizeof(sPlaceName), iPlaceSize);
		
		PushArrayString(hPlaces, sPlaceName);
		
		//LogMessage("Parsed place! %s [%d]", sPlaceName, iPlaceIndex);
	}
	
	if (GetArraySize(hPlaces) <= 0)
	{
		CloseHandle(hPlaces);
		hPlaces = INVALID_HANDLE;
	}
	
	// Get any unnamed areas.
	new iNavUnnamedAreas;
	if (iNavVersion > 11)
	{
		ReadFileCell(hFile, iNavUnnamedAreas, UNSIGNED_CHAR_BYTE_SIZE);
		
		LogMessage("Has unnamed areas: %d", iNavUnnamedAreas);
	}
	
	// Get area count.
	new iAreaCount;
	ReadFileCell(hFile, iAreaCount, UNSIGNED_INT_BYTE_SIZE);
	
	LogMessage("Area count: %d", iAreaCount);
	
	// Parse through areas, if any.
	new Handle:hAreas = CreateArray(NavMeshArea_MaxStats);
	new Handle:hAreaConnections = CreateArray(NavMeshConnection_MaxStats);
	new Handle:hAreaHidingSpots = CreateArray(NavMeshHidingSpot_MaxStats);
	new Handle:hAreaEncounterPaths = CreateArray(NavMeshEncounterPath_MaxStats);
	new Handle:hAreaEncounterSpots = CreateArray(NavMeshEncounterSpot_MaxStats);
	new Handle:hAreaLadderConnections = CreateArray(NavMeshLadderConnection_MaxStats);
	new Handle:hAreaVisibleAreas = CreateArray(NavMeshVisibleArea_MaxStats);
	
	if (iAreaCount > 0)
	{
		// The following are index values that will serve as starting and ending markers for areas
		// to determine what is theirs.
		
		// This is to avoid iteration of the whole area set to reduce lookup time.
		
		new iGlobalConnectionsStartIndex;
		new iGlobalHidingSpotsStartIndex;
		new iGlobalEncounterPathsStartIndex;
		new iGlobalEncounterSpotsStartIndex;
		new iGlobalLadderConnectionsStartIndex;
		new iGlobalVisibleAreasStartIndex;
		
		for (new iAreaIndex = 0; iAreaIndex < iAreaCount; iAreaIndex++)
		{
			new iAreaID;
			new Float:x1, Float:y1, Float:z1, Float:x2, Float:y2, Float:z2;
			new iAreaFlags;
			new iInheritVisibilityFrom;
			new iHidingSpotCount;
			new iVisibleAreaCount;
			new Float:flEarliestOccupyTimeFirstTeam;
			new Float:flEarliestOccupyTimeSecondTeam;
			new Float:flNECornerZ;
			new Float:flSWCornerZ;
			new iPlaceID;
			new unk01;
			
			ReadFileCell(hFile, iAreaID, UNSIGNED_INT_BYTE_SIZE);
			
			//LogMessage("Area ID: %d", iAreaID);
			
			if (iNavVersion <= 8) 
			{
				ReadFileCell(hFile, iAreaFlags, UNSIGNED_CHAR_BYTE_SIZE);
			}
			else if (iNavVersion < 13) 
			{
				ReadFileCell(hFile, iAreaFlags, UNSIGNED_SHORT_BYTE_SIZE);
			}
			else 
			{
				ReadFileCell(hFile, iAreaFlags, UNSIGNED_INT_BYTE_SIZE);
			}
			
			//LogMessage("Area Flags: %d", iAreaFlags);
			
			ReadFileCell(hFile, _:x1, FLOAT_BYTE_SIZE);
			ReadFileCell(hFile, _:y1, FLOAT_BYTE_SIZE);
			ReadFileCell(hFile, _:z1, FLOAT_BYTE_SIZE);
			ReadFileCell(hFile, _:x2, FLOAT_BYTE_SIZE);
			ReadFileCell(hFile, _:y2, FLOAT_BYTE_SIZE);
			ReadFileCell(hFile, _:z2, FLOAT_BYTE_SIZE);
			
			//LogMessage("Area extent: (%f, %f, %f), (%f, %f, %f)", x1, y1, z1, x2, y2, z2);
			
			// Cache the center position for faster performance.
			decl Float:flAreaCenter[3];
			flAreaCenter[0] = (x1 + x2) / 2.0;
			flAreaCenter[1] = (y1 + y2) / 2.0;
			flAreaCenter[2] = (z1 + z2) / 2.0;
			
			new Float:flInvDxCorners = 0.0; 
			new Float:flInvDyCorners = 0.0;
			
			if ((x2 - x1) > 0.0 && (y2 - y1) > 0.0)
			{
				flInvDxCorners = 1.0 / (x2 - x1);
				flInvDyCorners = 1.0 / (y2 - y1);
			}
			
			ReadFileCell(hFile, _:flNECornerZ, FLOAT_BYTE_SIZE);
			ReadFileCell(hFile, _:flSWCornerZ, FLOAT_BYTE_SIZE);
			
			//LogMessage("Corners: NW(%f), SW(%f)", flNECornerZ, flSWCornerZ);
			
			new iConnectionsStartIndex = -1;
			new iConnectionsEndIndex = -1;
			
			// Find connections.
			for (new iDirection = 0; iDirection < NAV_DIR_COUNT; iDirection++)
			{
				new iConnectionCount;
				ReadFileCell(hFile, iConnectionCount, UNSIGNED_INT_BYTE_SIZE);
				
				//LogMessage("Connection count: %d", iConnectionCount);
				
				if (iConnectionCount > 0)
				{
					if (iConnectionsStartIndex == -1) iConnectionsStartIndex = iGlobalConnectionsStartIndex;
				
					for (new iConnectionIndex = 0; iConnectionIndex < iConnectionCount; iConnectionIndex++) 
					{
						iConnectionsEndIndex = iGlobalConnectionsStartIndex;
					
						new iConnectingAreaID;
						ReadFileCell(hFile, iConnectingAreaID, UNSIGNED_INT_BYTE_SIZE);
						
						new iIndex = PushArrayCell(hAreaConnections, iConnectingAreaID);
						SetArrayCell(hAreaConnections, iIndex, iDirection, NavMeshConnection_Direction);
						
						iGlobalConnectionsStartIndex++;
					}
				}
			}
			
			// Get hiding spots.
			ReadFileCell(hFile, iHidingSpotCount, UNSIGNED_CHAR_BYTE_SIZE);
			
			//LogMessage("Hiding spot count: %d", iHidingSpotCount);
			
			new iHidingSpotsStartIndex = -1;
			new iHidingSpotsEndIndex = -1;
			
			if (iHidingSpotCount > 0)
			{
				iHidingSpotsStartIndex = iGlobalHidingSpotsStartIndex;
				
				for (new iHidingSpotIndex = 0; iHidingSpotIndex < iHidingSpotCount; iHidingSpotIndex++)
				{
					iHidingSpotsEndIndex = iGlobalHidingSpotsStartIndex;
				
					new iHidingSpotID;
					ReadFileCell(hFile, iHidingSpotID, UNSIGNED_INT_BYTE_SIZE);
					
					new Float:flHidingSpotX, Float:flHidingSpotY, Float:flHidingSpotZ;
					ReadFileCell(hFile, _:flHidingSpotX, FLOAT_BYTE_SIZE);
					ReadFileCell(hFile, _:flHidingSpotY, FLOAT_BYTE_SIZE);
					ReadFileCell(hFile, _:flHidingSpotZ, FLOAT_BYTE_SIZE);
					
					new iHidingSpotFlags;
					ReadFileCell(hFile, iHidingSpotFlags, UNSIGNED_CHAR_BYTE_SIZE);
					
					new iIndex = PushArrayCell(hAreaHidingSpots, iHidingSpotID);
					SetArrayCell(hAreaHidingSpots, iIndex, flHidingSpotX, NavMeshHidingSpot_X);
					SetArrayCell(hAreaHidingSpots, iIndex, flHidingSpotY, NavMeshHidingSpot_Y);
					SetArrayCell(hAreaHidingSpots, iIndex, flHidingSpotZ, NavMeshHidingSpot_Z);
					SetArrayCell(hAreaHidingSpots, iIndex, iHidingSpotFlags, NavMeshHidingSpot_Flags);
					
					iGlobalHidingSpotsStartIndex++;
					
					//LogMessage("Parsed hiding spot (%f, %f, %f) with ID [%d] and flags [%d]", flHidingSpotX, flHidingSpotY, flHidingSpotZ, iHidingSpotID, iHidingSpotFlags);
				}
			}
			
			// Get approach areas (old version, only used to read data)
			if (iNavVersion < 15)
			{
				new iApproachAreaCount;
				ReadFileCell(hFile, iApproachAreaCount, UNSIGNED_CHAR_BYTE_SIZE);
				
				for (new iApproachAreaIndex = 0; iApproachAreaIndex < iApproachAreaCount; iApproachAreaIndex++)
				{
					new iApproachHereID;
					ReadFileCell(hFile, iApproachHereID, UNSIGNED_INT_BYTE_SIZE);
					
					new iApproachPrevID;
					ReadFileCell(hFile, iApproachPrevID, UNSIGNED_INT_BYTE_SIZE);
					
					new iApproachType;
					ReadFileCell(hFile, iApproachType, UNSIGNED_CHAR_BYTE_SIZE);
					
					new iApproachNextID;
					ReadFileCell(hFile, iApproachNextID, UNSIGNED_INT_BYTE_SIZE);
					
					new iApproachHow;
					ReadFileCell(hFile, iApproachHow, UNSIGNED_CHAR_BYTE_SIZE);
				}
			}
			
			// Get encounter paths.
			new iEncounterPathCount;
			ReadFileCell(hFile, iEncounterPathCount, UNSIGNED_INT_BYTE_SIZE);
			
			//LogMessage("Encounter Path Count: %d", iEncounterPathCount);
			
			new iEncounterPathsStartIndex = -1;
			new iEncounterPathsEndIndex = -1;
			
			if (iEncounterPathCount > 0)
			{
				iEncounterPathsStartIndex = iGlobalEncounterPathsStartIndex;
			
				for (new iEncounterPathIndex = 0; iEncounterPathIndex < iEncounterPathCount; iEncounterPathIndex++)
				{
					iEncounterPathsEndIndex = iGlobalEncounterPathsStartIndex;
				
					new iEncounterFromID;
					ReadFileCell(hFile, iEncounterFromID, UNSIGNED_INT_BYTE_SIZE);
					
					new iEncounterFromDirection;
					ReadFileCell(hFile, iEncounterFromDirection, UNSIGNED_CHAR_BYTE_SIZE);
					
					new iEncounterToID;
					ReadFileCell(hFile, iEncounterToID, UNSIGNED_INT_BYTE_SIZE);
					
					new iEncounterToDirection;
					ReadFileCell(hFile, iEncounterToDirection, UNSIGNED_CHAR_BYTE_SIZE);
					
					new iEncounterSpotCount;
					ReadFileCell(hFile, iEncounterSpotCount, UNSIGNED_CHAR_BYTE_SIZE);
					
					//LogMessage("Encounter [from ID %d] [from dir %d] [to ID %d] [to dir %d] [spot count %d]", iEncounterFromID, iEncounterFromDirection, iEncounterToID, iEncounterToDirection, iEncounterSpotCount);
					
					new iEncounterSpotsStartIndex = -1;
					new iEncounterSpotsEndIndex = -1;
					
					if (iEncounterSpotCount > 0)
					{
						iEncounterSpotsStartIndex = iGlobalEncounterSpotsStartIndex;
					
						for (new iEncounterSpotIndex = 0; iEncounterSpotIndex < iEncounterSpotCount; iEncounterSpotIndex++)
						{
							iEncounterSpotsEndIndex = iGlobalEncounterSpotsStartIndex;
						
							new iEncounterSpotOrderID;
							ReadFileCell(hFile, iEncounterSpotOrderID, UNSIGNED_INT_BYTE_SIZE);
							
							new iEncounterSpotT;
							ReadFileCell(hFile, iEncounterSpotT, UNSIGNED_CHAR_BYTE_SIZE);
							
							new Float:flEncounterSpotParametricDistance = float(iEncounterSpotT) / 255.0;
							
							new iIndex = PushArrayCell(hAreaEncounterSpots, iEncounterSpotOrderID);
							SetArrayCell(hAreaEncounterSpots, iIndex, flEncounterSpotParametricDistance, NavMeshEncounterSpot_ParametricDistance);
							
							iGlobalEncounterSpotsStartIndex++;
							
							//LogMessage("Encounter spot [order id %d] and [T %d]", iEncounterSpotOrderID, iEncounterSpotT);
						}
					}
					
					new iIndex = PushArrayCell(hAreaEncounterPaths, iEncounterFromID);
					SetArrayCell(hAreaEncounterPaths, iIndex, iEncounterFromDirection, NavMeshEncounterPath_FromDirection);
					SetArrayCell(hAreaEncounterPaths, iIndex, iEncounterToID, NavMeshEncounterPath_ToID);
					SetArrayCell(hAreaEncounterPaths, iIndex, iEncounterToDirection, NavMeshEncounterPath_ToDirection);
					SetArrayCell(hAreaEncounterPaths, iIndex, iEncounterSpotsStartIndex, NavMeshEncounterPath_SpotsStartIndex);
					SetArrayCell(hAreaEncounterPaths, iIndex, iEncounterSpotsEndIndex, NavMeshEncounterPath_SpotsEndIndex);
					
					iGlobalEncounterPathsStartIndex++;
				}
			}
			
			ReadFileCell(hFile, iPlaceID, UNSIGNED_SHORT_BYTE_SIZE);
			
			//LogMessage("Place ID: %d", iPlaceID);
			
			// Get ladder connections.
			
			new iLadderConnectionsStartIndex = -1;
			new iLadderConnectionsEndIndex = -1;
			
			for (new iLadderDirection = 0; iLadderDirection < NAV_LADDER_DIR_COUNT; iLadderDirection++)
			{
				new iLadderConnectionCount;
				ReadFileCell(hFile, iLadderConnectionCount, UNSIGNED_INT_BYTE_SIZE);
				
				//LogMessage("Ladder Connection Count: %d", iLadderConnectionCount);
				
				if (iLadderConnectionCount > 0)
				{
					iLadderConnectionsStartIndex = iGlobalLadderConnectionsStartIndex;
				
					for (new iLadderConnectionIndex = 0; iLadderConnectionIndex < iLadderConnectionCount; iLadderConnectionIndex++)
					{
						iLadderConnectionsEndIndex = iGlobalLadderConnectionsStartIndex;
					
						new iLadderConnectionID;
						ReadFileCell(hFile, iLadderConnectionID, UNSIGNED_INT_BYTE_SIZE);
						
						new iIndex = PushArrayCell(hAreaLadderConnections, iLadderConnectionID);
						SetArrayCell(hAreaLadderConnections, iIndex, iLadderDirection, NavMeshLadderConnection_Direction);
						
						iGlobalLadderConnectionsStartIndex++;
						
						//LogMessage("Parsed ladder connect [ID %d]\n", iLadderConnectionID);
					}
				}
			}
			
			ReadFileCell(hFile, _:flEarliestOccupyTimeFirstTeam, FLOAT_BYTE_SIZE);
			ReadFileCell(hFile, _:flEarliestOccupyTimeSecondTeam, FLOAT_BYTE_SIZE);
			
			new Float:flNavCornerLightIntensityNW;
			new Float:flNavCornerLightIntensityNE;
			new Float:flNavCornerLightIntensitySE;
			new Float:flNavCornerLightIntensitySW;
			
			new iVisibleAreasStartIndex = -1;
			new iVisibleAreasEndIndex = -1;
			
			if (iNavVersion >= 11)
			{
				ReadFileCell(hFile, _:flNavCornerLightIntensityNW, FLOAT_BYTE_SIZE);
				ReadFileCell(hFile, _:flNavCornerLightIntensityNE, FLOAT_BYTE_SIZE);
				ReadFileCell(hFile, _:flNavCornerLightIntensitySE, FLOAT_BYTE_SIZE);
				ReadFileCell(hFile, _:flNavCornerLightIntensitySW, FLOAT_BYTE_SIZE);
				
				if (iNavVersion >= 16)
				{
					ReadFileCell(hFile, iVisibleAreaCount, UNSIGNED_INT_BYTE_SIZE);
					
					//LogMessage("Visible area count: %d", iVisibleAreaCount);
					
					if (iVisibleAreaCount > 0)
					{
						iVisibleAreasStartIndex = iGlobalVisibleAreasStartIndex;
					
						for (new iVisibleAreaIndex = 0; iVisibleAreaIndex < iVisibleAreaCount; iVisibleAreaIndex++)
						{
							iVisibleAreasEndIndex = iGlobalVisibleAreasStartIndex;
						
							new iVisibleAreaID;
							ReadFileCell(hFile, iVisibleAreaID, UNSIGNED_INT_BYTE_SIZE);
							
							new iVisibleAreaAttributes;
							ReadFileCell(hFile, iVisibleAreaAttributes, UNSIGNED_CHAR_BYTE_SIZE);
							
							new iIndex = PushArrayCell(hAreaVisibleAreas, iVisibleAreaID);
							SetArrayCell(hAreaVisibleAreas, iIndex, iVisibleAreaAttributes, NavMeshVisibleArea_Attributes);
							
							iGlobalVisibleAreasStartIndex++;
							
							//LogMessage("Parsed visible area [%d] with attr [%d]", iVisibleAreaID, iVisibleAreaAttributes);
						}
					}
					
					ReadFileCell(hFile, iInheritVisibilityFrom, UNSIGNED_INT_BYTE_SIZE);
					
					//LogMessage("Inherit visibilty from: %d", iInheritVisibilityFrom);
					
					ReadFileCell(hFile, unk01, UNSIGNED_INT_BYTE_SIZE);
				}
			}
			
			new iIndex = PushArrayCell(hAreas, iAreaID);
			SetArrayCell(hAreas, iIndex, iAreaFlags, NavMeshArea_Flags);
			SetArrayCell(hAreas, iIndex, iPlaceID, NavMeshArea_PlaceID);
			SetArrayCell(hAreas, iIndex, x1, NavMeshArea_X1);
			SetArrayCell(hAreas, iIndex, y1, NavMeshArea_Y1);
			SetArrayCell(hAreas, iIndex, z1, NavMeshArea_Z1);
			SetArrayCell(hAreas, iIndex, x2, NavMeshArea_X2);
			SetArrayCell(hAreas, iIndex, y2, NavMeshArea_Y2);
			SetArrayCell(hAreas, iIndex, z2, NavMeshArea_Z2);
			SetArrayCell(hAreas, iIndex, flAreaCenter[0], NavMeshArea_CenterX);
			SetArrayCell(hAreas, iIndex, flAreaCenter[1], NavMeshArea_CenterY);
			SetArrayCell(hAreas, iIndex, flAreaCenter[2], NavMeshArea_CenterZ);
			SetArrayCell(hAreas, iIndex, flInvDxCorners, NavMeshArea_InvDxCorners);
			SetArrayCell(hAreas, iIndex, flInvDyCorners, NavMeshArea_InvDyCorners);
			SetArrayCell(hAreas, iIndex, flNECornerZ, NavMeshArea_NECornerZ);
			SetArrayCell(hAreas, iIndex, flSWCornerZ, NavMeshArea_SWCornerZ);
			SetArrayCell(hAreas, iIndex, iConnectionsStartIndex, NavMeshArea_ConnectionsStartIndex);
			SetArrayCell(hAreas, iIndex, iConnectionsEndIndex, NavMeshArea_ConnectionsEndIndex);
			SetArrayCell(hAreas, iIndex, iHidingSpotsStartIndex, NavMeshArea_HidingSpotsStartIndex);
			SetArrayCell(hAreas, iIndex, iHidingSpotsEndIndex, NavMeshArea_HidingSpotsEndIndex);
			SetArrayCell(hAreas, iIndex, iEncounterPathsStartIndex, NavMeshArea_EncounterPathsStartIndex);
			SetArrayCell(hAreas, iIndex, iEncounterPathsEndIndex, NavMeshArea_EncounterPathsEndIndex);
			SetArrayCell(hAreas, iIndex, iLadderConnectionsStartIndex, NavMeshArea_LadderConnectionsStartIndex);
			SetArrayCell(hAreas, iIndex, iLadderConnectionsEndIndex, NavMeshArea_LadderConnectionsEndIndex);
			SetArrayCell(hAreas, iIndex, flNavCornerLightIntensityNW, NavMeshArea_CornerLightIntensityNW);
			SetArrayCell(hAreas, iIndex, flNavCornerLightIntensityNE, NavMeshArea_CornerLightIntensityNE);
			SetArrayCell(hAreas, iIndex, flNavCornerLightIntensitySE, NavMeshArea_CornerLightIntensitySE);
			SetArrayCell(hAreas, iIndex, flNavCornerLightIntensitySW, NavMeshArea_CornerLightIntensitySW);
			SetArrayCell(hAreas, iIndex, iVisibleAreasStartIndex, NavMeshArea_VisibleAreasStartIndex);
			SetArrayCell(hAreas, iIndex, iVisibleAreasEndIndex, NavMeshArea_VisibleAreasEndIndex);
			SetArrayCell(hAreas, iIndex, iInheritVisibilityFrom, NavMeshArea_InheritVisibilityFrom);
			SetArrayCell(hAreas, iIndex, flEarliestOccupyTimeFirstTeam, NavMeshArea_EarliestOccupyTimeFirstTeam);
			SetArrayCell(hAreas, iIndex, flEarliestOccupyTimeSecondTeam, NavMeshArea_EarliestOccupyTimeSecondTeam);
			SetArrayCell(hAreas, iIndex, unk01, NavMeshArea_unk01);
			SetArrayCell(hAreas, iIndex, -1, NavMeshArea_Parent);
			SetArrayCell(hAreas, iIndex, NUM_TRAVERSE_TYPES, NavMeshArea_ParentHow);
			SetArrayCell(hAreas, iIndex, 0, NavMeshArea_TotalCost);
			SetArrayCell(hAreas, iIndex, 0, NavMeshArea_CostSoFar);
			SetArrayCell(hAreas, iIndex, -1, NavMeshArea_Marker);
			SetArrayCell(hAreas, iIndex, -1, NavMeshArea_OpenMarker);
			SetArrayCell(hAreas, iIndex, -1, NavMeshArea_PrevOpenIndex);
			SetArrayCell(hAreas, iIndex, -1, NavMeshArea_NextOpenIndex);
			SetArrayCell(hAreas, iIndex, 0.0, NavMeshArea_PathLengthSoFar);
			SetArrayCell(hAreas, iIndex, false, NavMeshArea_Blocked);
		}
	}
	
	new iLadderCount;
	ReadFileCell(hFile, iLadderCount, UNSIGNED_INT_BYTE_SIZE);
	
	new Handle:hLadders = CreateArray(NavMeshLadder_MaxStats);
	
	if (iLadderCount > 0)
	{
		for (new iLadderIndex; iLadderIndex < iLadderCount; iLadderIndex++)
		{
			new iLadderID;
			ReadFileCell(hFile, iLadderID, UNSIGNED_INT_BYTE_SIZE);
			
			new Float:flLadderWidth;
			ReadFileCell(hFile, _:flLadderWidth, FLOAT_BYTE_SIZE);
			
			new Float:flLadderTopX, Float:flLadderTopY, Float:flLadderTopZ, Float:flLadderBottomX, Float:flLadderBottomY, Float:flLadderBottomZ;
			ReadFileCell(hFile, _:flLadderTopX, FLOAT_BYTE_SIZE);
			ReadFileCell(hFile, _:flLadderTopY, FLOAT_BYTE_SIZE);
			ReadFileCell(hFile, _:flLadderTopZ, FLOAT_BYTE_SIZE);
			ReadFileCell(hFile, _:flLadderBottomX, FLOAT_BYTE_SIZE);
			ReadFileCell(hFile, _:flLadderBottomY, FLOAT_BYTE_SIZE);
			ReadFileCell(hFile, _:flLadderBottomZ, FLOAT_BYTE_SIZE);
			
			new Float:flLadderLength;
			ReadFileCell(hFile, _:flLadderLength, FLOAT_BYTE_SIZE);
			
			new iLadderDirection;
			ReadFileCell(hFile, iLadderDirection, UNSIGNED_INT_BYTE_SIZE);
			
			new iLadderTopForwardAreaID;
			ReadFileCell(hFile, iLadderTopForwardAreaID, UNSIGNED_INT_BYTE_SIZE);
			
			new iLadderTopLeftAreaID;
			ReadFileCell(hFile, iLadderTopLeftAreaID, UNSIGNED_INT_BYTE_SIZE);
			
			new iLadderTopRightAreaID;
			ReadFileCell(hFile, iLadderTopRightAreaID, UNSIGNED_INT_BYTE_SIZE);
			
			new iLadderTopBehindAreaID;
			ReadFileCell(hFile, iLadderTopBehindAreaID, UNSIGNED_INT_BYTE_SIZE);
			
			new iLadderBottomAreaID;
			ReadFileCell(hFile, iLadderBottomAreaID, UNSIGNED_INT_BYTE_SIZE);
			
			new iIndex = PushArrayCell(hLadders, iLadderID);
			SetArrayCell(hLadders, iIndex, flLadderWidth, NavMeshLadder_Width);
			SetArrayCell(hLadders, iIndex, flLadderLength, NavMeshLadder_Length);
			SetArrayCell(hLadders, iIndex, flLadderTopX, NavMeshLadder_TopX);
			SetArrayCell(hLadders, iIndex, flLadderTopY, NavMeshLadder_TopY);
			SetArrayCell(hLadders, iIndex, flLadderTopZ, NavMeshLadder_TopZ);
			SetArrayCell(hLadders, iIndex, flLadderBottomX, NavMeshLadder_BottomX);
			SetArrayCell(hLadders, iIndex, flLadderBottomY, NavMeshLadder_BottomY);
			SetArrayCell(hLadders, iIndex, flLadderBottomZ, NavMeshLadder_BottomZ);
			SetArrayCell(hLadders, iIndex, iLadderDirection, NavMeshLadder_Direction);
			SetArrayCell(hLadders, iIndex, iLadderTopForwardAreaID, NavMeshLadder_TopForwardAreaIndex);
			SetArrayCell(hLadders, iIndex, iLadderTopLeftAreaID, NavMeshLadder_TopLeftAreaIndex);
			SetArrayCell(hLadders, iIndex, iLadderTopRightAreaID, NavMeshLadder_TopRightAreaIndex);
			SetArrayCell(hLadders, iIndex, iLadderTopBehindAreaID, NavMeshLadder_TopBehindAreaIndex);
			SetArrayCell(hLadders, iIndex, iLadderBottomAreaID, NavMeshLadder_BottomAreaIndex);
		}
	}
	
	new iFinalIndex = PushArrayCell(g_hNavMesh, iNavMagicNumber);
	SetArrayCell(g_hNavMesh, iFinalIndex, iNavVersion, NavMesh_Version);
	SetArrayCell(g_hNavMesh, iFinalIndex, iNavSubVersion, NavMesh_SubVersion);
	SetArrayCell(g_hNavMesh, iFinalIndex, iNavSaveBspSize, NavMesh_SaveBSPSize);
	SetArrayCell(g_hNavMesh, iFinalIndex, iNavMeshAnalyzed, NavMesh_IsMeshAnalyzed);
	SetArrayCell(g_hNavMesh, iFinalIndex, hPlaces, NavMesh_Places);
	SetArrayCell(g_hNavMesh, iFinalIndex, hAreas, NavMesh_Areas);
	SetArrayCell(g_hNavMesh, iFinalIndex, hAreaConnections, NavMesh_AreaConnections);
	SetArrayCell(g_hNavMesh, iFinalIndex, hAreaHidingSpots, NavMesh_AreaHidingSpots);
	SetArrayCell(g_hNavMesh, iFinalIndex, hAreaEncounterPaths, NavMesh_AreaEncounterPaths);
	SetArrayCell(g_hNavMesh, iFinalIndex, hAreaEncounterSpots, NavMesh_AreaEncounterSpots);
	SetArrayCell(g_hNavMesh, iFinalIndex, hAreaLadderConnections, NavMesh_AreaLadderConnections);
	SetArrayCell(g_hNavMesh, iFinalIndex, hAreaVisibleAreas, NavMesh_AreaVisibleAreas);
	SetArrayCell(g_hNavMesh, iFinalIndex, hLadders, NavMesh_Ladders);
	
	CloseHandle(hFile);
	
	// File parsing is all done. Convert IDs to array indexes for faster performance and 
	// lesser lookup time.
	
	if (GetArraySize(hAreaConnections) > 0)
	{
		for (new iIndex = 0, iSize = GetArraySize(hAreaConnections); iIndex < iSize; iIndex++)
		{
			new iConnectedAreaID = GetArrayCell(hAreaConnections, iIndex, NavMeshConnection_AreaIndex);
			SetArrayCell(hAreaConnections, iIndex, FindValueInArray(hAreas, iConnectedAreaID), NavMeshConnection_AreaIndex);
		}
	}
	
	if (GetArraySize(hAreaVisibleAreas) > 0)
	{
		for (new iIndex = 0, iSize = GetArraySize(hAreaVisibleAreas); iIndex < iSize; iIndex++)
		{
			new iVisibleAreaID = GetArrayCell(hAreaVisibleAreas, iIndex, NavMeshVisibleArea_Index);
			SetArrayCell(hAreaVisibleAreas, iIndex, FindValueInArray(hAreas, iVisibleAreaID), NavMeshVisibleArea_Index);
		}
	}
	
	if (GetArraySize(hAreaLadderConnections) > 0)
	{
		for (new iIndex = 0, iSize = GetArraySize(hAreaLadderConnections); iIndex < iSize; iIndex++)
		{
			new iLadderID = GetArrayCell(hAreaLadderConnections, iIndex, NavMeshLadderConnection_LadderIndex);
			SetArrayCell(hAreaLadderConnections, iIndex, FindValueInArray(hLadders, iLadderID), NavMeshLadderConnection_LadderIndex);
		}
	}
	
	if (GetArraySize(hLadders) > 0)
	{
		for (new iLadderIndex = 0; iLadderIndex < iLadderCount; iLadderIndex++)
		{
			new iTopForwardAreaID = GetArrayCell(hLadders, iLadderIndex, NavMeshLadder_TopForwardAreaIndex);
			SetArrayCell(hLadders, iLadderIndex, FindValueInArray(hAreas, iTopForwardAreaID), NavMeshLadder_TopForwardAreaIndex);
			
			new iTopLeftAreaID = GetArrayCell(hLadders, iLadderIndex, NavMeshLadder_TopLeftAreaIndex);
			SetArrayCell(hLadders, iLadderIndex, FindValueInArray(hAreas, iTopLeftAreaID), NavMeshLadder_TopLeftAreaIndex);
			
			new iTopRightAreaID = GetArrayCell(hLadders, iLadderIndex, NavMeshLadder_TopRightAreaIndex);
			SetArrayCell(hLadders, iLadderIndex, FindValueInArray(hAreas, iTopRightAreaID), NavMeshLadder_TopRightAreaIndex);
			
			new iTopBehindAreaID = GetArrayCell(hLadders, iLadderIndex, NavMeshLadder_TopBehindAreaIndex);
			SetArrayCell(hLadders, iLadderIndex, FindValueInArray(hAreas, iTopBehindAreaID), NavMeshLadder_TopBehindAreaIndex);
			
			new iBottomAreaID = GetArrayCell(hLadders, iLadderIndex, NavMeshLadder_BottomAreaIndex);
			SetArrayCell(hLadders, iLadderIndex, FindValueInArray(hAreas, iBottomAreaID), NavMeshLadder_BottomAreaIndex);
		}
	}
	
	return true;
}

NavMeshDestroy()
{
	for (new i = 0, iSize = GetArraySize(g_hNavMesh); i < iSize; i++)
	{
		new Handle:hDestroyThis = Handle:GetArrayCell(g_hNavMesh, i, NavMesh_Places);
		if (hDestroyThis != INVALID_HANDLE) CloseHandle(hDestroyThis);
		
		hDestroyThis = Handle:GetArrayCell(g_hNavMesh, i, NavMesh_Areas);
		if (hDestroyThis != INVALID_HANDLE) CloseHandle(hDestroyThis);
		
		hDestroyThis = Handle:GetArrayCell(g_hNavMesh, i, NavMesh_AreaConnections);
		if (hDestroyThis != INVALID_HANDLE) CloseHandle(hDestroyThis);
		
		hDestroyThis = Handle:GetArrayCell(g_hNavMesh, i, NavMesh_AreaHidingSpots);
		if (hDestroyThis != INVALID_HANDLE) CloseHandle(hDestroyThis);
		
		hDestroyThis = Handle:GetArrayCell(g_hNavMesh, i, NavMesh_AreaEncounterPaths);
		if (hDestroyThis != INVALID_HANDLE) CloseHandle(hDestroyThis);
		
		hDestroyThis = Handle:GetArrayCell(g_hNavMesh, i, NavMesh_AreaEncounterSpots);
		if (hDestroyThis != INVALID_HANDLE) CloseHandle(hDestroyThis);
		
		hDestroyThis = Handle:GetArrayCell(g_hNavMesh, i, NavMesh_AreaLadderConnections);
		if (hDestroyThis != INVALID_HANDLE) CloseHandle(hDestroyThis);
		
		hDestroyThis = Handle:GetArrayCell(g_hNavMesh, i, NavMesh_AreaVisibleAreas);
		if (hDestroyThis != INVALID_HANDLE) CloseHandle(hDestroyThis);
	}
	
	ClearArray(g_hNavMesh);
	
	g_bNavMeshBuilt = false;
	g_iNavMeshAreaOpenListIndex = -1;
	g_iNavMeshAreaOpenListTailIndex = -1;
	g_iNavMeshAreaMasterMarker = 0;
}

stock NavMeshAreaGetFlags(iAreaIndex)
{
	if (!g_bNavMeshBuilt) return 0;

	new Handle:hAreas = Handle:GetArrayCell(g_hNavMesh, 0, NavMesh_Areas);
	if (hAreas == INVALID_HANDLE) return 0;
	
	return GetArrayCell(hAreas, iAreaIndex, NavMeshArea_Flags);
}

stock bool:NavMeshAreaGetCenter(iAreaIndex, Float:flBuffer[3])
{
	if (!g_bNavMeshBuilt) return false;
	
	new Handle:hAreas = Handle:GetArrayCell(g_hNavMesh, 0, NavMesh_Areas);
	if (hAreas == INVALID_HANDLE) return false;
	
	flBuffer[0] = Float:GetArrayCell(hAreas, iAreaIndex, NavMeshArea_CenterX);
	flBuffer[1] = Float:GetArrayCell(hAreas, iAreaIndex, NavMeshArea_CenterY);
	flBuffer[2] = Float:GetArrayCell(hAreas, iAreaIndex, NavMeshArea_CenterZ);
	return true;
}

stock Handle:NavMeshAreaGetAdjacentList(iAreaIndex, iNavDirection)
{
	if (!g_bNavMeshBuilt) return INVALID_HANDLE;

	new Handle:hAreas = Handle:GetArrayCell(g_hNavMesh, 0, NavMesh_Areas);
	if (hAreas == INVALID_HANDLE) return INVALID_HANDLE;
	
	new iConnectionsStartIndex = GetArrayCell(hAreas, iAreaIndex, NavMeshArea_ConnectionsStartIndex);
	if (iConnectionsStartIndex == -1) return INVALID_HANDLE;
	
	new iConnectionsEndIndex = GetArrayCell(hAreas, iAreaIndex, NavMeshArea_ConnectionsEndIndex);
	
	new Handle:hStack = CreateStack();
	new Handle:hConnections = Handle:GetArrayCell(g_hNavMesh, 0, NavMesh_AreaConnections);
	
	for (new i = iConnectionsStartIndex; i <= iConnectionsEndIndex; i++)
	{
		if (GetArrayCell(hConnections, i, NavMeshConnection_Direction) == iNavDirection)
		{
			PushStackCell(hStack, GetArrayCell(hConnections, i, NavMeshConnection_AreaIndex));
		}
	}
	
	return hStack;
}

stock Handle:NavMeshAreaGetLadderList(iAreaIndex, iLadderDir)
{
	if (!g_bNavMeshBuilt) return INVALID_HANDLE;
	
	new Handle:hAreas = Handle:GetArrayCell(g_hNavMesh, 0, NavMesh_Areas);
	if (hAreas == INVALID_HANDLE) return INVALID_HANDLE;
	
	new iLadderConnectionsStartIndex = GetArrayCell(hAreas, iAreaIndex, NavMeshArea_LadderConnectionsStartIndex);
	if (iLadderConnectionsStartIndex == -1) return INVALID_HANDLE;
	
	new iLadderConnectionsEndIndex = GetArrayCell(hAreas, iAreaIndex, NavMeshArea_LadderConnectionsEndIndex);
	
	new Handle:hStack = CreateStack();
	new Handle:hLadderConnections = Handle:GetArrayCell(g_hNavMesh, 0, NavMesh_AreaLadderConnections);
	
	for (new i = iLadderConnectionsStartIndex; i <= iLadderConnectionsEndIndex; i++)
	{
		if (GetArrayCell(hLadderConnections, i, NavMeshLadderConnection_Direction) == iLadderDir)
		{
			PushStackCell(hStack, GetArrayCell(hLadderConnections, i, NavMeshLadderConnection_LadderIndex));
		}
	}
	
	return hStack;
}

stock NavMeshAreaGetTotalCost(iAreaIndex)
{
	if (!g_bNavMeshBuilt) return 0;

	new Handle:hAreas = Handle:GetArrayCell(g_hNavMesh, 0, NavMesh_Areas);
	if (hAreas == INVALID_HANDLE) return 0;
	
	return GetArrayCell(hAreas, iAreaIndex, NavMeshArea_TotalCost);
}

stock NavMeshAreaGetCostSoFar(iAreaIndex)
{
	if (!g_bNavMeshBuilt) return 0;

	new Handle:hAreas = Handle:GetArrayCell(g_hNavMesh, 0, NavMesh_Areas);
	if (hAreas == INVALID_HANDLE) return 0;
	
	return GetArrayCell(hAreas, iAreaIndex, NavMeshArea_CostSoFar);
}

stock NavMeshAreaGetParent(iAreaIndex)
{
	if (!g_bNavMeshBuilt) return -1;

	new Handle:hAreas = Handle:GetArrayCell(g_hNavMesh, 0, NavMesh_Areas);
	if (hAreas == INVALID_HANDLE) return -1;
	
	return GetArrayCell(hAreas, iAreaIndex, NavMeshArea_Parent);
}

stock NavMeshAreaGetParentHow(iAreaIndex)
{
	if (!g_bNavMeshBuilt) return NUM_TRAVERSE_TYPES;

	new Handle:hAreas = Handle:GetArrayCell(g_hNavMesh, 0, NavMesh_Areas);
	if (hAreas == INVALID_HANDLE) return NUM_TRAVERSE_TYPES;
	
	return GetArrayCell(hAreas, iAreaIndex, NavMeshArea_ParentHow);
}

stock NavMeshAreaSetParent(iAreaIndex, iParentAreaIndex)
{
	if (!g_bNavMeshBuilt) return;

	new Handle:hAreas = Handle:GetArrayCell(g_hNavMesh, 0, NavMesh_Areas);
	if (hAreas == INVALID_HANDLE) return;
	
	SetArrayCell(hAreas, iAreaIndex, iParentAreaIndex, NavMeshArea_Parent);
}

stock NavMeshAreaSetParentHow(iAreaIndex, iParentHow)
{
	if (!g_bNavMeshBuilt) return;

	new Handle:hAreas = Handle:GetArrayCell(g_hNavMesh, 0, NavMesh_Areas);
	if (hAreas == INVALID_HANDLE) return;
	
	SetArrayCell(hAreas, iAreaIndex, iParentHow, NavMeshArea_ParentHow);
}

stock bool:NavMeshAreaGetExtentLow(iAreaIndex, Float:flBuffer[3])
{
	if (!g_bNavMeshBuilt) return false;

	new Handle:hAreas = Handle:GetArrayCell(g_hNavMesh, 0, NavMesh_Areas);
	if (hAreas == INVALID_HANDLE) return false;
	
	flBuffer[0] = Float:GetArrayCell(hAreas, iAreaIndex, NavMeshArea_X1);
	flBuffer[1] = Float:GetArrayCell(hAreas, iAreaIndex, NavMeshArea_Y1);
	flBuffer[2] = Float:GetArrayCell(hAreas, iAreaIndex, NavMeshArea_Z1);
	return true;
}

stock bool:NavMeshAreaGetExtentHigh(iAreaIndex, Float:flBuffer[3])
{
	if (!g_bNavMeshBuilt) return false;

	new Handle:hAreas = Handle:GetArrayCell(g_hNavMesh, 0, NavMesh_Areas);
	if (hAreas == INVALID_HANDLE) return false;
	
	flBuffer[0] = Float:GetArrayCell(hAreas, iAreaIndex, NavMeshArea_X2);
	flBuffer[1] = Float:GetArrayCell(hAreas, iAreaIndex, NavMeshArea_Y2);
	flBuffer[2] = Float:GetArrayCell(hAreas, iAreaIndex, NavMeshArea_Z2);
	return true;
}

stock bool:NavMeshAreaIsOverlappingPoint(iAreaIndex, const Float:flPos[3], Float:flTolerance)
{
	if (!g_bNavMeshBuilt) return false;

	new Handle:hAreas = Handle:GetArrayCell(g_hNavMesh, 0, NavMesh_Areas);
	if (hAreas == INVALID_HANDLE) return false;
	
	decl Float:flExtentLow[3], Float:flExtentHigh[3];
	NavMeshAreaGetExtentLow(iAreaIndex, flExtentLow);
	NavMeshAreaGetExtentHigh(iAreaIndex, flExtentHigh);
	
	if (flPos[0] + flTolerance >= flExtentLow[0] &&
		flPos[0] - flTolerance <= flExtentHigh[0] &&
		flPos[1] + flTolerance >= flExtentLow[1] &&
		flPos[1] - flTolerance <= flExtentHigh[1])
	{
		return true;
	}
	
	return false;
}

stock bool:NavMeshAreaIsOverlappingArea(iAreaIndex, iTargetAreaIndex)
{
	if (!g_bNavMeshBuilt) return false;

	new Handle:hAreas = Handle:GetArrayCell(g_hNavMesh, 0, NavMesh_Areas);
	if (hAreas == INVALID_HANDLE) return false;
	
	decl Float:flExtentLow[3], Float:flExtentHigh[3];
	NavMeshAreaGetExtentLow(iAreaIndex, flExtentLow);
	NavMeshAreaGetExtentHigh(iAreaIndex, flExtentHigh);
	
	decl Float:flTargetExtentLow[3], Float:flTargetExtentHigh[3];
	NavMeshAreaGetExtentLow(iTargetAreaIndex, flTargetExtentLow);
	NavMeshAreaGetExtentHigh(iTargetAreaIndex, flTargetExtentHigh);
	
	if (flTargetExtentLow[0] < flExtentHigh[0] &&
		flTargetExtentHigh[0] > flExtentLow[0] &&
		flTargetExtentLow[1] < flExtentHigh[1] &&
		flTargetExtentHigh[1] > flExtentLow[1])
	{
		return true;
	}
	
	return false;
}

stock Float:NavMeshAreaGetNECornerZ(iAreaIndex)
{
	if (!g_bNavMeshBuilt) return 0.0;

	new Handle:hAreas = Handle:GetArrayCell(g_hNavMesh, 0, NavMesh_Areas);
	if (hAreas == INVALID_HANDLE) return 0.0;
	
	return Float:GetArrayCell(hAreas, iAreaIndex, NavMeshArea_NECornerZ);
}

stock Float:NavMeshAreaGetSWCornerZ(iAreaIndex)
{
	if (!g_bNavMeshBuilt) return 0.0;

	new Handle:hAreas = Handle:GetArrayCell(g_hNavMesh, 0, NavMesh_Areas);
	if (hAreas == INVALID_HANDLE) return 0.0;
	
	return Float:GetArrayCell(hAreas, iAreaIndex, NavMeshArea_SWCornerZ);
}

stock Float:NavMeshAreaGetZ(iAreaIndex, const Float:flPos[3])
{
	if (!g_bNavMeshBuilt) return 0.0;

	new Handle:hAreas = Handle:GetArrayCell(g_hNavMesh, 0, NavMesh_Areas);
	if (hAreas == INVALID_HANDLE) return 0.0;
	
	decl Float:flExtentLow[3], Float:flExtentHigh[3];
	NavMeshAreaGetExtentLow(iAreaIndex, flExtentLow);
	NavMeshAreaGetExtentHigh(iAreaIndex, flExtentHigh);
	
	new Float:dx = flExtentHigh[0] - flExtentLow[0];
	new Float:dy = flExtentHigh[1] - flExtentLow[1];
	
	new Float:flNEZ = NavMeshAreaGetNECornerZ(iAreaIndex);
	
	if (dx == 0.0 || dy == 0.0)
	{
		return flNEZ;
	}
	
	new Float:u = (flPos[0] - flExtentLow[0]) / dx;
	new Float:v = (flPos[1] - flExtentLow[1]) / dy;
	
	u = FloatClamp(u, 0.0, 1.0);
	v = FloatClamp(v, 0.0, 1.0);
	
	new Float:flSWZ = NavMeshAreaGetSWCornerZ(iAreaIndex);
	
	new Float:flNorthZ = flExtentLow[2] + u * (flNEZ - flExtentLow[2]);
	new Float:flSouthZ = flSWZ + u * (flExtentHigh[2] - flSWZ);
	
	return flNorthZ + v * (flSouthZ - flNorthZ);
}

stock Float:NavMeshAreaGetZFromXAndY(iAreaIndex, Float:x, Float:y)
{
	if (!g_bNavMeshBuilt) return 0.0;

	new Handle:hAreas = Handle:GetArrayCell(g_hNavMesh, 0, NavMesh_Areas);
	if (hAreas == INVALID_HANDLE) return 0.0;
	
	new Float:flInvDxCorners = Float:GetArrayCell(hAreas, iAreaIndex, NavMeshArea_InvDxCorners);
	new Float:flInvDyCorners = Float:GetArrayCell(hAreas, iAreaIndex, NavMeshArea_InvDyCorners);
	
	new Float:flNECornerZ = Float:GetArrayCell(hAreas, iAreaIndex, NavMeshArea_NECornerZ);
	
	if (flInvDxCorners == 0.0 || flInvDyCorners == 0.0)
	{
		return flNECornerZ;
	}
	
	decl Float:flExtentLow[3], Float:flExtentHigh[3];
	NavMeshAreaGetExtentLow(iAreaIndex, flExtentLow);
	NavMeshAreaGetExtentHigh(iAreaIndex, flExtentHigh);

	new Float:u = (x - flExtentLow[0]) * flInvDxCorners;
	new Float:v = (y - flExtentLow[1]) * flInvDyCorners;
	
	u = FloatClamp(u, 0.0, 1.0);
	v = FloatClamp(v, 0.0, 1.0);
	
	new Float:flSWCornerZ = Float:GetArrayCell(hAreas, iAreaIndex, NavMeshArea_SWCornerZ);
	
	new Float:flNorthZ = flExtentLow[2] + u * (flNECornerZ - flExtentLow[2]);
	new Float:flSouthZ = flSWCornerZ + u * (flExtentHigh[2] - flSWCornerZ);
	
	return flNorthZ + v * (flSouthZ - flNorthZ);
}

#define StepHeight 18.0

stock bool:NavMeshAreaContains(iAreaIndex, const Float:flPos[3])
{
	if (!g_bNavMeshBuilt) return false;
	
	new Handle:hAreas = Handle:GetArrayCell(g_hNavMesh, 0, NavMesh_Areas);
	if (hAreas == INVALID_HANDLE) return false;
	
	if (!NavMeshAreaIsOverlappingPoint(iAreaIndex, flPos, 0.0)) return false;
	
	new Float:flMyZ = NavMeshAreaGetZ(iAreaIndex, flPos);
	
	if ((flMyZ - StepHeight) > flPos[2]) return false;
	
	for (new i = 0, iSize = GetArraySize(hAreas); i < iSize; i++)
	{
		if (i == iAreaIndex) continue;
		
		if (!NavMeshAreaIsOverlappingArea(iAreaIndex, i)) continue;
		
		new Float:flTheirZ = NavMeshAreaGetZ(i, flPos);
		if ((flTheirZ - StepHeight) > flPos[2]) continue;
		
		if (flTheirZ > flMyZ)
		{
			return false;
		}
	}
	
	return true;
}

stock bool:NavMeshAreaComputePortal(iAreaIndex, iAreaToIndex, iNavDirection, Float:flCenter[3], &Float:flHalfWidth)
{
	if (!g_bNavMeshBuilt) return false;
	
	new Handle:hAreas = Handle:GetArrayCell(g_hNavMesh, 0, NavMesh_Areas);
	if (hAreas == INVALID_HANDLE) return false;

	decl Float:flAreaExtentLow[3], Float:flAreaExtentHigh[3];
	NavMeshAreaGetExtentLow(iAreaIndex, flAreaExtentLow);
	NavMeshAreaGetExtentHigh(iAreaIndex, flAreaExtentHigh);
	
	decl Float:flAreaToExtentLow[3], Float:flAreaToExtentHigh[3];
	NavMeshAreaGetExtentLow(iAreaToIndex, flAreaToExtentLow);
	NavMeshAreaGetExtentHigh(iAreaToIndex, flAreaToExtentHigh);
	
	if (iNavDirection == NAV_DIR_NORTH || iNavDirection == NAV_DIR_SOUTH)
	{
		if (iNavDirection == NAV_DIR_NORTH)
		{
			flCenter[1] = flAreaExtentLow[1];
		}
		else
		{
			flCenter[1] = flAreaExtentHigh[1];
		}
		
		new Float:flLeft = flAreaExtentLow[0] > flAreaToExtentLow[0] ? flAreaExtentLow[0] : flAreaToExtentLow[0];
		new Float:flRight = flAreaExtentHigh[0] < flAreaToExtentHigh[0] ? flAreaExtentHigh[0] : flAreaToExtentHigh[0];
		
		if (flLeft < flAreaExtentLow[0]) flLeft = flAreaExtentLow[0];
		else if (flLeft > flAreaExtentHigh[0]) flLeft = flAreaExtentHigh[0];
		
		if (flRight < flAreaExtentLow[0]) flRight = flAreaExtentLow[0];
		else if (flRight > flAreaExtentHigh[0]) flRight = flAreaExtentHigh[0];
		
		flCenter[0] = (flLeft + flRight) / 2.0;
		flHalfWidth = (flRight - flLeft) / 2.0;
	}
	else
	{
		if (iNavDirection == NAV_DIR_WEST)
		{
			flCenter[0] = flAreaExtentLow[0];
		}
		else
		{
			flCenter[0] = flAreaExtentHigh[0];
		}
		
		new Float:flTop = flAreaExtentLow[1] > flAreaToExtentLow[1] ? flAreaExtentLow[1] : flAreaToExtentLow[1];
		new Float:flBottom = flAreaExtentHigh[1] < flAreaToExtentHigh[1] ? flAreaExtentHigh[1] : flAreaToExtentHigh[1];
		
		if (flTop < flAreaExtentLow[1]) flTop = flAreaExtentLow[1];
		else if (flTop > flAreaExtentHigh[1]) flTop = flAreaExtentHigh[1];
		
		if (flBottom < flAreaExtentLow[1]) flBottom = flAreaExtentLow[1];
		else if (flBottom > flAreaExtentHigh[1]) flBottom = flAreaExtentHigh[1];
		
		flCenter[1] = (flTop + flBottom) / 2.0;
		flHalfWidth = (flBottom - flTop) / 2.0;
	}
	
	flCenter[2] = NavMeshAreaGetZFromXAndY(iAreaIndex, flCenter[0], flCenter[1]);
	
	return true;
}

stock Float:FloatMin(Float:a, Float:b)
{
	if (a < b) return a;
	return b;
}

stock Float:FloatMax(Float:a, Float:b)
{
	if (a > b) return a;
	return b;
}

stock bool:NavMeshAreaComputeClosestPointInPortal(iAreaIndex, iAreaToIndex, iNavDirection, const Float:flFromPos[3], Float:flClosestPos[3])
{
	if (!g_bNavMeshBuilt) return false;
	
	new Handle:hAreas = Handle:GetArrayCell(g_hNavMesh, 0, NavMesh_Areas);
	if (hAreas == INVALID_HANDLE) return false;

	static Float:flMargin = 25.0; // GenerationStepSize = 25.0;
	
	decl Float:flAreaExtentLow[3], Float:flAreaExtentHigh[3];
	NavMeshAreaGetExtentLow(iAreaIndex, flAreaExtentLow);
	NavMeshAreaGetExtentHigh(iAreaIndex, flAreaExtentHigh);
	
	decl Float:flAreaToExtentLow[3], Float:flAreaToExtentHigh[3];
	NavMeshAreaGetExtentLow(iAreaToIndex, flAreaToExtentLow);
	NavMeshAreaGetExtentHigh(iAreaToIndex, flAreaToExtentHigh);
	
	if (iNavDirection == NAV_DIR_NORTH || iNavDirection == NAV_DIR_SOUTH)
	{
		if (iNavDirection == NAV_DIR_NORTH)
		{
			flClosestPos[1] = flAreaExtentLow[1];
		}
		else
		{
			flClosestPos[1] = flAreaExtentHigh[1];
		}
		
		new Float:flLeft = FloatMax(flAreaExtentLow[0], flAreaToExtentLow[0]);
		new Float:flRight = FloatMin(flAreaExtentHigh[0], flAreaToExtentHigh[0]);
		
		new Float:flLeftMargin = NavMeshAreaIsEdge(iAreaToIndex, NAV_DIR_WEST) ? (flLeft + flMargin) : flLeft;
		new Float:flRightMargin = NavMeshAreaIsEdge(iAreaToIndex, NAV_DIR_EAST) ? (flRight - flMargin) : flRight;
		
		if (flLeftMargin > flRightMargin)
		{
			new Float:flMid = (flLeft + flRight) / 2.0;
			flLeftMargin = flMid;
			flRightMargin = flMid;
		}
		
		if (flFromPos[0] < flLeftMargin)
		{
			flClosestPos[0] = flLeftMargin;
		}
		else if (flFromPos[0] > flRightMargin)
		{
			flClosestPos[0] = flRightMargin;
		}
		else
		{
			flClosestPos[0] = flFromPos[0];
		}
	}
	else
	{
		if (iNavDirection == NAV_DIR_WEST)
		{
			flClosestPos[0] = flAreaExtentLow[0];
		}
		else
		{
			flClosestPos[0] = flAreaExtentHigh[0];
		}
		
		new Float:flTop = FloatMax(flAreaExtentLow[1], flAreaToExtentLow[1]);
		new Float:flBottom = FloatMin(flAreaExtentHigh[1], flAreaToExtentHigh[1]);
		
		new Float:flTopMargin = NavMeshAreaIsEdge(iAreaToIndex, NAV_DIR_NORTH) ? (flTop + flMargin) : flTop;
		new Float:flBottomMargin = NavMeshAreaIsEdge(iAreaToIndex, NAV_DIR_SOUTH) ? (flBottom - flMargin) : flBottom;
		
		if (flTopMargin > flBottomMargin)
		{
			new Float:flMid = (flTop + flBottom) / 2.0;
			flTopMargin = flMid;
			flBottomMargin = flMid;
		}
		
		if (flFromPos[1] < flTopMargin)
		{
			flClosestPos[1] = flTopMargin;
		}
		else if (flFromPos[1] > flBottomMargin)
		{
			flClosestPos[1] = flBottomMargin;
		}
		else
		{
			flClosestPos[1] = flFromPos[1];
		}
	}
	
	flClosestPos[2] = NavMeshAreaGetZFromXAndY(iAreaIndex, flClosestPos[0], flClosestPos[1]);
	
	return true;
}

stock NavMeshAreaComputeDirection(iAreaIndex, const Float:flPos[3])
{
	if (!g_bNavMeshBuilt) return NAV_DIR_COUNT;
	
	new Handle:hAreas = Handle:GetArrayCell(g_hNavMesh, 0, NavMesh_Areas);
	if (hAreas == INVALID_HANDLE) return NAV_DIR_COUNT;
	
	decl Float:flExtentLow[3], Float:flExtentHigh[3];
	NavMeshAreaGetExtentLow(iAreaIndex, flExtentLow);
	NavMeshAreaGetExtentHigh(iAreaIndex, flExtentHigh);
	
	if (flPos[0] >= flExtentLow[0] && flPos[0] <= flExtentHigh[0])
	{
		if (flPos[1] < flExtentLow[1])
		{
			return NAV_DIR_NORTH;
		}
		else if (flPos[1] > flExtentHigh[1])
		{
			return NAV_DIR_SOUTH;
		}
	}
	else if (flPos[1] >= flExtentLow[1] && flPos[1] <= flExtentHigh[1])
	{
		if (flPos[0] < flExtentLow[0])
		{
			return NAV_DIR_WEST;
		}
		else if (flPos[0] > flExtentHigh[0])
		{
			return NAV_DIR_EAST;
		}
	}
	
	decl Float:flCenter[3];
	NavMeshAreaGetCenter(iAreaIndex, flCenter);
	
	decl Float:flTo[3];
	SubtractVectors(flPos, flCenter, flTo);
	
	if (FloatAbs(flTo[0]) > FloatAbs(flTo[1]))
	{
		if (flTo[0] > 0.0) return NAV_DIR_EAST;
		
		return NAV_DIR_WEST;
	}
	else
	{
		if (flTo[1] > 0.0) return NAV_DIR_SOUTH;
		
		return NAV_DIR_NORTH;
	}
}

stock Float:NavMeshAreaGetLightIntensity(iAreaIndex, const Float:flPos[3])
{
	if (!g_bNavMeshBuilt) return 0.0;
	
	new Handle:hAreas = Handle:GetArrayCell(g_hNavMesh, 0, NavMesh_Areas);
	if (hAreas == INVALID_HANDLE) return 0.0;
	
	decl Float:flExtentLow[3], Float:flExtentHigh[3];
	NavMeshAreaGetExtentLow(iAreaIndex, flExtentLow);
	NavMeshAreaGetExtentHigh(iAreaIndex, flExtentHigh);

	decl Float:flTestPos[3];
	flTestPos[0] = FloatClamp(flPos[0], flExtentLow[0], flExtentHigh[0]);
	flTestPos[1] = FloatClamp(flPos[1], flExtentLow[1], flExtentHigh[1]);
	flTestPos[2] = flPos[2];
	
	new Float:dX = (flTestPos[0] - flExtentLow[0]) / (flExtentHigh[0] - flExtentLow[0]);
	new Float:dY = (flTestPos[1] - flExtentLow[1]) / (flExtentHigh[1] - flExtentLow[1]);
	
	new Float:flCornerLightIntensityNW = Float:GetArrayCell(hAreas, iAreaIndex, NavMeshArea_CornerLightIntensityNW);
	new Float:flCornerLightIntensityNE = Float:GetArrayCell(hAreas, iAreaIndex, NavMeshArea_CornerLightIntensityNE);
	new Float:flCornerLightIntensitySW = Float:GetArrayCell(hAreas, iAreaIndex, NavMeshArea_CornerLightIntensitySW);
	new Float:flCornerLightIntensitySE = Float:GetArrayCell(hAreas, iAreaIndex, NavMeshArea_CornerLightIntensitySE);
	
	new Float:flNorthLight = flCornerLightIntensityNW * (1.0 - dX) + flCornerLightIntensityNE * dX;
	new Float:flSouthLight = flCornerLightIntensitySW * (1.0 - dX) + flCornerLightIntensitySE * dX;
	
	return (flNorthLight * (1.0 - dY) + flSouthLight * dY);
}


stock Float:FloatClamp(Float:a, Float:min, Float:max)
{
	if (a < min) a = min;
	if (a > max) a = max;
	return a;
}

stock bool:NavMeshAreaIsEdge(iAreaIndex, iNavDirection)
{
	new Handle:hConnections = NavMeshAreaGetAdjacentList(iAreaIndex, iNavDirection);
	if (hConnections == INVALID_HANDLE || IsStackEmpty(hConnections))
	{
		if (hConnections != INVALID_HANDLE) CloseHandle(hConnections);
		return true;
	}
	
	if (hConnections != INVALID_HANDLE) CloseHandle(hConnections);
	return false;
}

stock Float:NavMeshLadderGetLength(iLadderIndex)
{
	if (!g_bNavMeshBuilt) return 0.0;

	new Handle:hLadders = Handle:GetArrayCell(g_hNavMesh, 0, NavMesh_Ladders);
	if (hLadders == INVALID_HANDLE) return 0.0;
	
	return Float:GetArrayCell(hLadders, iLadderIndex, NavMeshLadder_Length);
}

stock NavMeshGetArea(const Float:flPos[3])
{
	if (!g_bNavMeshBuilt) return -1;
	
	new Handle:hAreas = Handle:GetArrayCell(g_hNavMesh, 0, NavMesh_Areas);
	if (hAreas == INVALID_HANDLE) return -1;
	
	for (new iAreaIndex = 0, iAreaCount = GetArraySize(hAreas); iAreaIndex < iAreaCount; iAreaIndex++)
	{
		if (NavMeshAreaContains(iAreaIndex, flPos))
		{
			return iAreaIndex;
		}
	}
	
	return -1;
}

#define HalfHumanHeight 35.5

stock bool:NavMeshGetGroundHeight(const Float:flPos[3], &Float:flHeight, Float:flNormal[3])
{
	static Float:flMaxOffset = 100.0;
	
	decl Float:flTo[3], Float:flFrom[3];
	flTo[0] = flPos[0];
	flTo[1] = flPos[1];
	flTo[2] = flPos[2] - 10000.0;
	
	flFrom[0] = flPos[0];
	flFrom[1] = flPos[1];
	flFrom[2] = flPos[2] + HalfHumanHeight + 0.001;
	
	while (flTo[2] - flPos[2] < flMaxOffset)
	{
		new Handle:hTrace = TR_TraceRayEx(flFrom, flTo, MASK_NPCSOLID_BRUSHONLY, RayType_EndPoint);
		new bool:bDidHit = TR_DidHit(hTrace);
		new Float:flFraction = TR_GetFraction(hTrace);
		decl Float:flPlaneNormal[3];
		decl Float:flEndPos[3];
		TR_GetEndPosition(flEndPos, hTrace);
		TR_GetPlaneNormal(hTrace, flPlaneNormal);
		CloseHandle(hTrace);
		
		if (!bDidHit && ((flFraction == 1.0 ) || ((flFrom[2] - flEndPos[2]) >= HalfHumanHeight)))
		{
			flHeight = flEndPos[2];
			flNormal[0] = flPlaneNormal[0];
			flNormal[1] = flPlaneNormal[1];
			flNormal[2] = flPlaneNormal[2];
			
			return true;
		}
		
		flTo[2] = (flFraction == 0.0) ? flFrom[2] : flEndPos[2];
		flFrom[2] = flTo[2] + HalfHumanHeight + 0.001;
	}
	
	flHeight = 0.0;
	flNormal[0] = 0.0;
	flNormal[1] = 0.0;
	flNormal[2] = 1.0;
	return false;
}

stock NavMeshGetNearestArea(const Float:flPos[3], Float:flMaxDist)
{
	if (!g_bNavMeshBuilt) return -1;
	
	new Handle:hAreas = Handle:GetArrayCell(g_hNavMesh, 0, NavMesh_Areas);
	if (hAreas == INVALID_HANDLE) return -1;
	
	new iBestAreaIndex = -1;
	new bool:bHasBestAreaIndex = false;
	new Float:flBestAreaDist = 0.0;
	
	for (new iAreaIndex = 0, iAreaCount = GetArraySize(hAreas); iAreaIndex < iAreaCount; iAreaIndex++)
	{
		decl Float:flCenter[3];
		NavMeshAreaGetCenter(iAreaIndex, flCenter);
		
		new Float:flDist = GetVectorDistance(flCenter, flPos);
		
		if ((flMaxDist <= 0.0 || flDist < flMaxDist) &&
			(!bHasBestAreaIndex || (flDist < flBestAreaDist)))
		{
			iBestAreaIndex = iAreaIndex;
			flBestAreaDist = flDist;
			bHasBestAreaIndex = true;
		}
	}
	
	return iBestAreaIndex;
}

//	==================================
//	API
//	==================================

public Native_NavMeshExists(Handle:plugin, numParams)
{
	return g_bNavMeshBuilt;
}

public Native_NavMeshGetMagicNumber(Handle:plugin, numParams)
{
	if (!g_bNavMeshBuilt)
	{
		LogError("Could not retrieve magic number because the nav mesh doesn't exist!");
		return -1;
	}
	
	return GetArrayCell(g_hNavMesh, 0, NavMesh_MagicNumber);
}

public Native_NavMeshGetVersion(Handle:plugin, numParams)
{
	if (!g_bNavMeshBuilt)
	{
		LogError("Could not retrieve version because the nav mesh doesn't exist!");
		return -1;
	}
	
	return GetArrayCell(g_hNavMesh, 0, NavMesh_Version);
}

public Native_NavMeshGetSubVersion(Handle:plugin, numParams)
{
	if (!g_bNavMeshBuilt)
	{
		LogError("Could not retrieve subversion because the nav mesh doesn't exist!");
		return -1;
	}
	
	return GetArrayCell(g_hNavMesh, 0, NavMesh_SubVersion);
}

public Native_NavMeshGetSaveBSPSize(Handle:plugin, numParams)
{
	if (!g_bNavMeshBuilt)
	{
		LogError("Could not retrieve save BSP size because the nav mesh doesn't exist!");
		return -1;
	}
	
	return GetArrayCell(g_hNavMesh, 0, NavMesh_SaveBSPSize);
}

public Native_NavMeshIsAnalyzed(Handle:plugin, numParams)
{
	if (!g_bNavMeshBuilt)
	{
		LogError("Could not retrieve analysis state because the nav mesh doesn't exist!");
		return 0;
	}
	
	return GetArrayCell(g_hNavMesh, 0, NavMesh_IsMeshAnalyzed);
}

public Native_NavMeshGetPlaces(Handle:plugin, numParams)
{
	if (!g_bNavMeshBuilt)
	{
		LogError("Could not retrieve place list because the nav mesh doesn't exist!");
		return _:INVALID_HANDLE;
	}
	
	return GetArrayCell(g_hNavMesh, 0, NavMesh_Places);
}

public Native_NavMeshGetAreas(Handle:plugin, numParams)
{
	if (!g_bNavMeshBuilt)
	{
		LogError("Could not retrieve area list because the nav mesh doesn't exist!");
		return _:INVALID_HANDLE;
	}
	
	return GetArrayCell(g_hNavMesh, 0, NavMesh_Areas);
}

public Native_NavMeshGetLadders(Handle:plugin, numParams)
{
	if (!g_bNavMeshBuilt)
	{
		LogError("Could not retrieve ladder list because the nav mesh doesn't exist!");
		return _:INVALID_HANDLE;
	}
	
	return GetArrayCell(g_hNavMesh, 0, NavMesh_Ladders);
}

public Native_NavMeshBuildPath(Handle:plugin, numParams)
{
	decl Float:flGoalPos[3];
	GetNativeArray(3, flGoalPos, 3);
	
	new iClosestIndex = GetNativeCellRef(6);
	
	new bool:bResult = NavMeshBuildPath(GetNativeCell(1), 
		GetNativeCell(2), 
		flGoalPos,
		plugin,
		Function:GetNativeCell(4),
		GetNativeCell(5),
		iClosestIndex,
		Float:GetNativeCell(7));
		
	SetNativeCellRef(6, iClosestIndex);
	return bResult;
}

public Native_NavMeshGetArea(Handle:plugin, numParams)
{
	decl Float:flPos[3];
	GetNativeArray(1, flPos, 3);

	return NavMeshGetArea(flPos);
}

public Native_NavMeshGetNearestArea(Handle:plugin, numParams)
{
	decl Float:flPos[3];
	GetNativeArray(1, flPos, 3);
	
	return NavMeshGetNearestArea(flPos, Float:GetNativeCell(2));
}

public Native_NavMeshAreaGetMasterMarker(Handle:plugin, numParams)
{
	return g_iNavMeshAreaMasterMarker;
}

public Native_NavMeshAreaChangeMasterMarker(Handle:plugin, numParams)
{
	g_iNavMeshAreaMasterMarker++;
}

public Native_NavMeshAreaGetFlags(Handle:plugin, numParams)
{
	return NavMeshAreaGetFlags(GetNativeCell(1));
}

public Native_NavMeshAreaGetCenter(Handle:plugin, numParams)
{
	decl Float:flResult[3];
	if (NavMeshAreaGetCenter(GetNativeCell(1), flResult))
	{
		SetNativeArray(2, flResult, 3);
		return true;
	}
	
	return false;
}

public Native_NavMeshAreaGetAdjacentList(Handle:plugin, numParams)
{
	return _:NavMeshAreaGetAdjacentList(GetNativeCell(1), GetNativeCell(2));
}

public Native_NavMeshAreaGetLadderList(Handle:plugin, numParams)
{
	return _:NavMeshAreaGetLadderList(GetNativeCell(1), GetNativeCell(2));
}

public Native_NavMeshAreaGetTotalCost(Handle:plugin, numParams)
{
	return NavMeshAreaGetTotalCost(GetNativeCell(1));
}

public Native_NavMeshAreaGetCostSoFar(Handle:plugin, numParams)
{
	return NavMeshAreaGetCostSoFar(GetNativeCell(1));
}

public Native_NavMeshAreaGetParent(Handle:plugin, numParams)
{
	return NavMeshAreaGetParent(GetNativeCell(1));
}

public Native_NavMeshAreaGetParentHow(Handle:plugin, numParams)
{
	return NavMeshAreaGetParentHow(GetNativeCell(1));
}

public Native_NavMeshAreaSetParent(Handle:plugin, numParams)
{
	NavMeshAreaSetParent(GetNativeCell(1), GetNativeCell(2));
}

public Native_NavMeshAreaSetParentHow(Handle:plugin, numParams)
{
	NavMeshAreaSetParentHow(GetNativeCell(1), GetNativeCell(2));
}

public Native_NavMeshAreaGetExtentLow(Handle:plugin, numParams)
{
	decl Float:flExtent[3];
	if (NavMeshAreaGetExtentLow(GetNativeCell(1), flExtent))
	{
		SetNativeArray(2, flExtent, 3);
		return true;
	}
	
	return false;
}

public Native_NavMeshAreaGetExtentHigh(Handle:plugin, numParams)
{
	decl Float:flExtent[3];
	if (NavMeshAreaGetExtentHigh(GetNativeCell(1), flExtent))
	{
		SetNativeArray(2, flExtent, 3);
		return true;
	}
	
	return false;
}

public Native_NavMeshAreaIsOverlappingPoint(Handle:plugin, numParams)
{
	decl Float:flPos[3];
	GetNativeArray(2, flPos, 3);
	
	return NavMeshAreaIsOverlappingPoint(GetNativeCell(1), flPos, Float:GetNativeCell(3));
}

public Native_NavMeshAreaIsOverlappingArea(Handle:plugin, numParams)
{
	return NavMeshAreaIsOverlappingArea(GetNativeCell(1), GetNativeCell(2));
}

public Native_NavMeshAreaGetNECornerZ(Handle:plugin, numParams)
{
	return _:NavMeshAreaGetNECornerZ(GetNativeCell(1));
}

public Native_NavMeshAreaGetSWCornerZ(Handle:plugin, numParams)
{
	return _:NavMeshAreaGetSWCornerZ(GetNativeCell(1));
}

public Native_NavMeshAreaGetZ(Handle:plugin, numParams)
{
	decl Float:flPos[3];
	GetNativeArray(2, flPos, 3);

	return _:NavMeshAreaGetZ(GetNativeCell(1), flPos);
}

public Native_NavMeshAreaGetZFromXAndY(Handle:plugin, numParams)
{
	return _:NavMeshAreaGetZFromXAndY(GetNativeCell(1), Float:GetNativeCell(2), Float:GetNativeCell(3));
}

public Native_NavMeshAreaContains(Handle:plugin, numParams)
{
	decl Float:flPos[3];
	GetNativeArray(2, flPos, 3);

	return NavMeshAreaContains(GetNativeCell(1), flPos);
}

public Native_NavMeshAreaComputePortal(Handle:plugin, numParams)
{
	new Float:flCenter[3];
	new Float:flHalfWidth = GetNativeCellRef(5);
	
	new bool:bResult = NavMeshAreaComputePortal(GetNativeCell(1),
		GetNativeCell(2),
		GetNativeCell(3),
		flCenter,
		flHalfWidth);
		
	SetNativeArray(4, flCenter, 3);
	SetNativeCellRef(5, flHalfWidth);
	return bResult;
}

public Native_NavMeshAreaComputeClosestPointInPortal(Handle:plugin, numParams)
{
	decl Float:flFromPos[3];
	GetNativeArray(4, flFromPos, 3);
	
	new Float:flClosestPos[3];

	new bool:bResult = NavMeshAreaComputeClosestPointInPortal(GetNativeCell(1),
		GetNativeCell(2),
		GetNativeCell(3),
		flFromPos,
		flClosestPos);
		
	SetNativeArray(5, flClosestPos, 3);
	return bResult;
}

public Native_NavMeshAreaComputeDirection(Handle:plugin, numParams)
{
	decl Float:flPos[3];
	GetNativeArray(2, flPos, 3);
	
	return NavMeshAreaComputeDirection(GetNativeCell(1), flPos);
}

public Native_NavMeshAreaGetLightIntensity(Handle:plugin, numParams)
{
	decl Float:flPos[3];
	GetNativeArray(2, flPos, 3);

	//return _:NavMeshAreaGetLightIntensity(GetNativeCell(1), flPos);
}

public Native_NavMeshLadderGetLength(Handle:plugin, numParams)
{
	return _:NavMeshLadderGetLength(GetNativeCell(1));
}