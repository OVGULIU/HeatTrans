(* ::Package:: *)

(* ::Section::Closed:: *)
(*Begin package*)


(* ::Subsection::Closed:: *)
(*Header comments*)


(* :Title: HeatTrans *)
(* :Context: HeatTrans` *)
(* :Author: Matevz Pintar *)
(* :Summary: Package for non-stationary of heat transfer simulation with AceFEM framework. *)
(* :Copyright: C3M d.o.o., 2019 *)

(* :Summary: *)


(* ::Subsection::Closed:: *)
(*Begin package*)


(* This enables using AceFEM also without Notebook interface.
It has to be called before BeginPackage, because AceFEM doesn't follow standard conventions. *)
If[
	Not@$Notebooks,
	Get["AceFEM`Remote`"]
];

(* "AceFEM`" context should be called before "AceCommon`", because it loads the AceFEM package,
meanwhile "AceCommon`" doesn't load the package, but puts it on $ContextPath inside the package. *)
BeginPackage["HeatTrans`",{"NDSolve`FEM`","AceFEM`","AceCommon`"}];

(* Clear definitions from package symbols in public and private context. *)
ClearAll["`*","`*`*"];


(* ::Subsection::Closed:: *)
(*Public symbols*)


HeatTransfer;
MakeMesh;
$DefaultMaterial;


(* ::Section::Closed:: *)
(*Code*)


(* Begin private context *)
Begin["`Private`"];


(* ::Subsection::Closed:: *)
(*Utilities*)


(* ::Subsubsection::Closed:: *)
(*Paths*)


(* Get the directory of the package, even if the code is evaluated from notebook package editor. 
	RuleDelayed is crucial to avoid evaluation of NotebookDirectory[] when FrontEnd is not available. *)
$packageDirectory=ReplaceAll[
	DirectoryName[$InputFileName],
	("":>NotebookDirectory[])
];


(* This finds element library (.dll or similar) in appropriate directory.
If it doesn't exist it compiles it from source (.C file). This avoids problems
with compilation of elements for other operating systems, assuming users have appropriate 
compiler installed. *)

(* Messages are attached to the main symbol which uses the function to find element library.*)
HeatTransfer::unsupported="$SystemID `1` is not supported in this package.";
HeatTransfer::compile="Element library `1` was not found for this $SystemID.
It will be compiled from source (.C) and saved for reuse.";

getLibrary[name_]:=Module[
	{ext,srcDir,libDir,src,lib},
	ext=Switch[$SystemID,
		"Windows-x86-64",".W64.dll",
		"Linux-x86-64",".L64.dll",
		"MacOSX-x86-64",".M64.dll",
		_,Message[HeatTransfer::unsupported,$SystemID];Abort[]
	];
	
	srcDir=FileNameJoin[{$packageDirectory,"LibraryResources","Source"}];
	libDir=FileNameJoin[{$packageDirectory,"LibraryResources",$SystemID}];
	src=FileNameJoin[{srcDir,name<>".c"}];
	lib=FileNameJoin[{libDir,name<>ext}];
	
	(* Use message attached to General symbol instead of some package symbol. *)
	If[
		Not@FileExistsQ[src],
		Message[General::noopen,src];Abort[]
	];
	
	If[Not@DirectoryQ[libDir],CreateDirectory[libDir]];
	(* If element library doesn't exist, compile it from source (.C) 
	and copy it to appropriate directory. *)
	If[
		Not@FileExistsQ[lib],
		Message[HeatTransfer::compile,FileNameTake@lib];
		SMTMakeDll@src;
		CopyFile[FileNameJoin[{srcDir,FileNameTake@lib}],lib];
		DeleteFile[FileNameJoin[{srcDir,FileNameTake@lib}]]
	];
	lib
];


(* ::Subsection::Closed:: *)
(*HeatTransfer*)


(* ::Subsubsection::Closed:: *)
(*Mesh*)


(* This function improves the quality of 2D mesh. 
It is copied from FEMAddOns package ( https://github.com/WolframResearch/FEMAddOns ) *)

laplacianElementMeshSmoothing[mesh_]:=Module[
	{n, vec, mat, adjacencyMatrix, mass, laplacian, typoOpt,
	bndVertices, interiorVertices, stiffness, load, newCoords},

	n = Length[mesh["Coordinates"]];
	vec = mesh["VertexElementConnectivity"];
	mat = Unitize[vec.Transpose[vec]];
	vec = Null;
	adjacencyMatrix = mat - DiagonalMatrix[Diagonal[mat]];
	mass = DiagonalMatrix[SparseArray[Total[adjacencyMatrix, {2}]]];
	stiffness = N[mass - adjacencyMatrix];
	adjacencyMatrix = Null;
	mass = Null;

	bndVertices =  Flatten[Join @@ ElementIncidents[mesh["PointElements"]]];
	interiorVertices = Complement[Range[1, n], bndVertices];

	stiffness[[bndVertices]] = IdentityMatrix[n, SparseArray][[bndVertices]];

	load = ConstantArray[0., {n, mesh["EmbeddingDimension"]}];
	load[[bndVertices]] = mesh["Coordinates"][[bndVertices]];

	newCoords = LinearSolve[stiffness, load];

	typoOpt = If[
			$VersionNumber <= 11.3,
			"CheckIncidentsCompletness" -> False,
			"CheckIncidentsCompleteness" -> False
		];

	ToElementMesh[
		"Coordinates" -> newCoords, 
		"MeshElements" -> mesh["MeshElements"], 
		"BoundaryElements" -> mesh["BoundaryElements"], 
		"PointElements" -> mesh["PointElements"], 
		typoOpt,
		"CheckIntersections" -> False, 
		"DeleteDuplicateCoordinates" -> False,
		"RegionHoles" -> mesh["RegionHoles"]
	]
];


MakeMesh::usage="MakeMesh[reg,ord] makes ElementMesh from 2D region reg with \"MeshOrder\"->ord.";
MakeMesh::badreg="Region should be a bounded region in 2D.";

MakeMesh//SyntaxInformation={"ArgumentsPattern"->{_,_}};

MakeMesh[region_,order:(1|2)]:=Module[
	{triMesh,maxBound},
	
	If[
		Not[BoundedRegionQ[region]&&RegionDimension[region]==2],
		Message[MakeMesh::badreg];Return[$Failed]
	];
	
	maxBound=Max[Differences/@RegionBounds[region]];
	triMesh=ToElementMesh[
		region,
		"MeshOrder"->1,
		"MeshElementType"->TriangleElement,
		MaxCellMeasure->{"Length"->maxBound/10},
		AccuracyGoal->2
	];
	
	MeshOrderAlteration[
		laplacianElementMeshSmoothing@SMTTriangularToQuad[triMesh],
		order
	]
];


(* ::Subsubsection::Closed:: *)
(*Setup*)


$DefaultMaterial::usage="$DefaultMaterial represents a set of default material properties.";

(* This is a utility symbol, useful for demonstration purpose. Units system is (kg,m,s). *)
$DefaultMaterial=<|"Conductivity"->55,"Density"->7800,"SpecificHeat"->470.|>;


assembleDomainData[material_Association,other_:{}]:=Join[{
	"kt0 *"->material["Conductivity"],
	"rho0 *"->material["Density"],
	"cp0 *"->material["SpecificHeat"]
	},
	other
];


setup//Options={"SaveResultsTo"->False,"Console"->Automatic};

(* We assume that profile mesh is always made of QuadElement (Q1 or Q2S topology) *)
setup[mesh_,material_,opts:OptionsPattern[]]:=Module[
	{order,solidElement,surfaceElement,resultsFile,consoleQ},
	
	(* Name of results file can be some given string or default name.*)
	resultsFile=ReplaceAll[
		OptionValue["SaveResultsTo"],
		{Automatic|True->"HeatTransfer",x_/;Not@StringQ[x]->False}
	];
	order=mesh["MeshOrder"];
	{solidElement,surfaceElement}=order/.{
		1-> {"HeatConductionD2Q1","HeatConvectionD2L1"},
		2-> {"HeatConductionD2Q2S","HeatConvectionD2L2"}
	};
	consoleQ=TrueQ[OptionValue["Console"]/.(Automatic->Not@$Notebooks)];
	
	SMTInputData["Console"->consoleQ];
	SMTAddDomain[{
		{"Solid",solidElement,assembleDomainData[material],"Source"->getLibrary[solidElement]},
		{"Surface",surfaceElement,{"h *"->10.,"Tamb *"->25.},"Source"->getLibrary[surfaceElement]}
	}];
	SMTAddMesh[mesh,
		{
		(order/.{1->"Q1",2->"Q2S"})->"Solid",
		(order/.{1->"L1",2->"L2"})->"Surface"
		},
		"BoundaryElements"->True
	];
	
	SMTAnalysis["DumpInputTo"->resultsFile]
];


(* ::Subsubsection::Closed:: *)
(*Analysis*)


analysis//Options={
	"InitialTemperature"->100.,
	"AmbientTemperature"->20.,
	"ConvectionCoefficient"->20.
};

analysis[mesh_,time_,noSteps_,opts:OptionsPattern[]]:=Module[
	{initialTemp,ambientTemp,conCoeff,timeSteps,reaped,data},
	
	initialTemp=OptionValue["InitialTemperature"];
	ambientTemp=OptionValue["AmbientTemperature"];
	conCoeff=Clip[OptionValue["ConvectionCoefficient"],{0.,Infinity}];
	
	timeSteps=Subdivide[0.,time,noSteps];
	
	SMTAddInitialBoundary["T",1->initialTemp,"Type"->"InitialCondition"];
	SMTDomainData["Surface","Data","h*"->conCoeff];
	SMTDomainData["Surface","Data","Tamb*"->ambientTemp];
	
	reaped=Reap@Do[
		SMTNextStep["t"->t];
		While[
			SMTConvergence[10^-8,15],
			SMTNewtonIteration[];
		];
		(* Save AceFEM result files if appropriate option is given at setup.*)
		If[
			MatchQ[SMTSession[[8]],1|2],
			SMTPut[SMTIData["Step"],SMTRData["Time"]]
		];
		Sow@SMTPostData["Temperature"]
		,
		{t,timeSteps}
	];
	
	data=Transpose[Last@reaped,{2,1,3}];
	(* Return InterpolatingFunction of temperature field, like NDSolve would.*)
	ElementMeshInterpolation[
		{timeSteps,mesh},
		data,
		InterpolationOrder->All,
		"ExtrapolationHandler"->{Function[Indeterminate],"WarningMessage"->False}
	]
];


(* ::Subsubsection::Closed:: *)
(*Main*)


HeatTransfer::usage="HeatTransfer[reg, time, material] simulates heat transfer on 2D Region reg.
HeatTransfer[mesh, time, material] accepts ElementMesh mesh as description of geometry.";
HeatTransfer::quadElms="\"MeshElements\" of given ElementMesh should be QuadElement type.";
HeatTransfer::timeSteps="Number of time steps `1` should be a positive integer.";

HeatTransfer//Options=Sort@Join[
	Options@setup,Options@analysis,
	{"NoTimeSteps"->Automatic,"MeshOrder"->1}
];

HeatTransfer//SyntaxInformation={"ArgumentsPattern"->{_,_,_,OptionsPattern[HeatTransfer]}};

HeatTransfer[region_?RegionQ,time_,material_,opts:OptionsPattern[]]:=Module[
	{mesh,order},
	
	order=OptionValue["MeshOrder"]/.Automatic->1;
	
	If[
		Not[BoundedRegionQ[region]&&RegionDimension[region]==2],
		Message[HeatTransfer::badreg];Return[$Failed]
	];
	
	mesh=MakeMesh[region,order];
	If[
		MatchQ[mesh,_ElementMesh],
		HeatTransfer[mesh,time,material,opts],
		$Failed
	]
];

(* ------------------------------------------------------------------------ *)

HeatTransfer[mesh_ElementMesh,time_,material_,opts:OptionsPattern[]]:=Module[
	{noSteps},
	
	noSteps=OptionValue["NoTimeSteps"]/.Automatic->10;
	If[
		MatchQ[noSteps,Except[_Integer?Positive]],
		Message[HeatTransfer::timeSteps,noSteps];Return[$Failed]
	];
	
	(* Currently we insist that only quadrilateral elements are used.*)
	If[
		(Head/@mesh["MeshElements"])=!={QuadElement},
		Message[HeatTransfer::quadElms];Return[$Failed]
	];
	
	setup[
		mesh,material,
		FilterRules[Join[{opts},Options[HeatTransfer]],Options@setup]
	];
	analysis[
		mesh,time,noSteps,
		FilterRules[Join[{opts},Options[HeatTransfer]],Options@analysis]
	]
];


(* ::Subsection:: *)
(*Postprocessing*)


(* ::Section::Closed:: *)
(*End package*)


End[]; (* "`Private`" *)


EndPackage[];


HeatTransfer::version="Recommended AceFEM package version is at least `1`.";

With[
	{ver=6.912},
	If[
		TrueQ@(ver>SMCSession[[16]]),
		Message[HeatTransfer::version,ToString@ver]
	]
];
