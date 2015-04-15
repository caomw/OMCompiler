/*
 * This file is part of OpenModelica.
 *
 * Copyright (c) 1998-2014, Open Source Modelica Consortium (OSMC),
 * c/o Linköpings universitet, Department of Computer and Information Science,
 * SE-58183 Linköping, Sweden.
 *
 * All rights reserved.
 *
 * THIS PROGRAM IS PROVIDED UNDER THE TERMS OF GPL VERSION 3 LICENSE OR
 * THIS OSMC PUBLIC LICENSE (OSMC-PL) VERSION 1.2.
 * ANY USE, REPRODUCTION OR DISTRIBUTION OF THIS PROGRAM CONSTITUTES
 * RECIPIENT'S ACCEPTANCE OF THE OSMC PUBLIC LICENSE OR THE GPL VERSION 3,
 * ACCORDING TO RECIPIENTS CHOICE.
 *
 * The OpenModelica software and the Open Source Modelica
 * Consortium (OSMC) Public License (OSMC-PL) are obtained
 * from OSMC, either from the above address,
 * from the URLs: http://www.ida.liu.se/projects/OpenModelica or
 * http://www.openmodelica.org, and in the OpenModelica distribution.
 * GNU version 3 is obtained from: http://www.gnu.org/copyleft/gpl.html.
 *
 * This program is distributed WITHOUT ANY WARRANTY; without
 * even the implied warranty of  MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE, EXCEPT AS EXPRESSLY SET FORTH
 * IN THE BY RECIPIENT SELECTED SUBSIDIARY LICENSE CONDITIONS OF OSMC-PL.
 *
 * See the full OSMC Public License conditions for more details.
 *
 */

encapsulated package HpcOmTaskGraph
" file:        HpcOmTaskGraph.mo
  package:     HpcOmTaskGraph
  description: HpcOmTaskGraph contains the whole logic to create a TaskGraph on BLT-Level

  RCS: $Id: HpcOmTaskGraph.mo 2013-05-24 11:12:35Z marcusw $
"
public import BackendDAE;
public import DAE;
public import GraphML;

protected import Array;
protected import BackendDAEOptimize;
protected import BackendDAEUtil;
protected import BackendDump;
protected import BackendEquation;
protected import BackendVariable;
protected import ComponentReference;
protected import DAEDump;
protected import Debug;
protected import Error;
protected import Expression;
protected import ExpressionSolve;
protected import Flags;
protected import HpcOmBenchmark;
protected import HpcOmEqSystems;
protected import HpcOmScheduler;
protected import List;
protected import SCode;
protected import System;
protected import Util;

protected import Absyn;
protected import DAEUtil;
protected import ExpressionDump;

//----------------------------
//  Graph Structure
//----------------------------

public type TaskGraph = array<list<Integer>>;

public type Communications = list<Communication>;

public uniontype Communication
  record COMMUNICATION
    //Variables that have to be transmitted
    Integer numberOfVars; //sum of {numOfIntegers,numOfFloats,numOfBoolean, numOfStrings}
    list<Integer> integerVars;
    list<Integer> floatVars;
    list<Integer> booleanVars;
    list<Integer> stringVars;
    //Other values
    Integer childNode;
    Real requiredTime;
  end COMMUNICATION;
end Communication;

public uniontype ComponentInfo
  record COMPONENTINFO
    Boolean isPartOfODESystem;    // true if the component belongs to the ode system
    Boolean isPartOfEventSystem;  // true if the component belongs to the event system
    Boolean isRemovedComponent;   // true if the component was added via appendRemovedEquations (e.g. it is a assert)
  end COMPONENTINFO;
end ComponentInfo;

// TODO: Store compParamMapping, compNames and compDescs in ComponentInfo
// TODO: Change nodeMark to compMarks

public uniontype TaskGraphMeta   // stores all the metadata for the TaskGraph
  record TASKGRAPHMETA
    array<list<Integer>> inComps; // all StrongComponents from the BLT that belong to the Nodes [nodeId = arrayIdx]
    array<tuple<Integer,Integer,Integer>> varCompMapping;  // maps each variable to <compIdx, eqSystemIdx, offset>. The offset is the sum of the varNumber of all eqSystems with a minor index.
    array<tuple<Integer,Integer,Integer>> eqCompMapping;  // maps each equation to <compIdx, eqSystemIdx, offset>. The offset is the sum of the eqNumber of all eqSystems with a minor index.
    array<list<Integer>> compParamMapping; // maps each scc to a list of parameters that are required for calculation. The indices are related to the known-parameter object of SHARED.
    array<String> compNames; // the name of the components (e.g. '{18:7}')
    array<String> compDescs;  // a description of the components (e.g. 'R5.R * R5.i = C2.vinternal FOR R5.i')
    array<tuple<Integer,Real>> exeCosts;  // the execution cost for the nodes <numberOfOperations, requiredCycles>
    array<Communications> commCosts;  // the communication cost tuple(_,numberOfVars,requiredCycles) for an edge from array[parentSCC] to tuple(childSCC,_,_)
    array<Integer> nodeMark;  // used for level informations -> this is currently not a nodeMark, its a componentMark
    array<ComponentInfo> compInformations; // used to store additional informations about the components
  end TASKGRAPHMETA;
end TaskGraphMeta;

//----------------------------------------------------------
//  Functions to build the task graph from the BLT structure
//----------------------------------------------------------

public function createTaskGraph "author: marcusw,waurich
  Creates a task graph on scc-level."
  input BackendDAE.BackendDAE iDAE;
  input Boolean iAnalyzeParameters = false; //set this to true if the parameter information of task graph meta should be filled
  output TaskGraph oGraph;
  output TaskGraphMeta oGraphData;
protected
  list<BackendDAE.EqSystem> systs;
  BackendDAE.Shared shared;
  TaskGraph graph;
  TaskGraphMeta graphData;
algorithm
  //Iterate over each system
  BackendDAE.DAE(systs,shared) := iDAE;
  (graph,graphData) := getEmptyTaskGraph(0,0,0);
  ((oGraph,oGraphData,_)) := List.fold(systs, function createTaskGraph0(iShared=shared, iAnalyzeParameters=iAnalyzeParameters), (graph,graphData,1));
end createTaskGraph;

protected function createTaskGraph0 "author: marcusw,waurich
  Creates a task graph out of the given system."
  input BackendDAE.EqSystem iSyst; //The input system which should be analysed
  input BackendDAE.Shared iShared;
  input Boolean iAnalyzeParameters;
  input tuple<TaskGraph,TaskGraphMeta,Integer> iGraphInfo; //<_,_,eqSysIdx>
  output tuple<TaskGraph,TaskGraphMeta,Integer> oGrapInfo;
protected
  BackendDAE.StrongComponents comps;
  BackendDAE.Variables vars;
  Integer numberOfEqs;
  DAE.FunctionTree sharedFuncs;
  TaskGraphMeta iGraphData;
  TaskGraphMeta tmpGraphData;
  TaskGraph iGraph;
  TaskGraph tmpGraph;

  array<Communications> commCosts;
  array<list<Integer>> inComps;
  array<list<Integer>> compParamMapping;
  array<tuple<Integer,Real>> exeCosts;
  array<Integer> nodeMark;
  array<tuple<Integer,Integer,Integer>> varCompMapping, eqCompMapping; //Map each variable to the scc that solves her
  array<String> compNames;
  array<String> compDescs;
  list<Integer> eventEqLst, eventVarLst, rootVars;
  Integer numberOfVars, numberOfEqs;
  array<ComponentInfo> compInformations;

  Integer eqSysIdx;
  tuple<TaskGraph,TaskGraphMeta,Integer> tplOut;

  BackendDAE.EqSystem syst;
  BackendDAE.IncidenceMatrix incidenceMatrix;
algorithm
  BackendDAE.EQSYSTEM(matching=BackendDAE.MATCHING(comps=comps), orderedVars=vars, orderedEqs=BackendDAE.EQUATION_ARRAY(numberOfElement=numberOfEqs)) := iSyst;
  BackendDAE.SHARED(functionTree=sharedFuncs) := iShared;
  (iGraph,iGraphData,eqSysIdx) := iGraphInfo;

  (_,incidenceMatrix,_) := BackendDAEUtil.getIncidenceMatrix(iSyst, BackendDAE.NORMAL(), SOME(sharedFuncs));
  numberOfVars := BackendVariable.varsSize(vars);
  (tmpGraph,tmpGraphData) := getEmptyTaskGraph(listLength(comps), numberOfVars, numberOfEqs);
  TASKGRAPHMETA(inComps=inComps, compNames=compNames, exeCosts=exeCosts, commCosts=commCosts, nodeMark=nodeMark, varCompMapping=varCompMapping, eqCompMapping=eqCompMapping, compParamMapping=compParamMapping, compInformations=compInformations) := tmpGraphData;
  //print("createTaskGraph0 try to get varCompMapping\n");
  (varCompMapping,eqCompMapping) := getVarEqCompMapping(comps, eqSysIdx, 0, 0, varCompMapping, eqCompMapping);
  //print("createTaskGraph0 varCompMapping created\n");
  compDescs := getEquationStrings(comps,iSyst);  //gets the description i.e. the whole equation, for every component
  ((tmpGraph,inComps,compParamMapping,commCosts,compNames,nodeMark,_)) := List.fold(comps, function createTaskGraph1(iSystInfo=(incidenceMatrix,iSyst,iShared,listLength(comps)),iVarInfo=(varCompMapping,eqCompMapping,{}),iAnalyzeParameters=iAnalyzeParameters),(tmpGraph,inComps,compParamMapping,commCosts,compNames,nodeMark,1));
  // gather the metadata
  tmpGraphData := TASKGRAPHMETA(inComps, varCompMapping, eqCompMapping, compParamMapping, compNames, compDescs, exeCosts, commCosts, nodeMark, compInformations);
  if(intGt(eqSysIdx,1)) then
    (tmpGraph,tmpGraphData) := taskGraphAppend(iGraph,iGraphData,tmpGraph,tmpGraphData);
  end if;
  oGrapInfo := ((tmpGraph,tmpGraphData,eqSysIdx+1));
end createTaskGraph0;

public function getSystemComponents "author: marcusw
  Returns all components of the given BackendDAE."
  input BackendDAE.BackendDAE iDae;
  output BackendDAE.StrongComponents oComps;
  output array<tuple<BackendDAE.EqSystem, Integer>> oMapping; //Map each component to <eqSystem, eqSystemIdx>
protected
  BackendDAE.EqSystems systs;
  List<tuple<BackendDAE.EqSystem,Integer>> tmpSystems;
  BackendDAE.StrongComponents tmpComps;
algorithm
  (oComps,oMapping) := match(iDae)
    case(BackendDAE.DAE(eqs=systs))
      equation
        ((tmpComps, tmpSystems,_)) = List.fold(systs,getSystemComponents0,({},{},1));
      then (tmpComps,listArray(tmpSystems));
    else fail();
  end match;
end getSystemComponents;

protected function getSystemComponents0 "author: marcusw
  Adds the information for the given EqSystem to the system mapping structure."
  input BackendDAE.EqSystem iSyst;
  input tuple<BackendDAE.StrongComponents, list<tuple<BackendDAE.EqSystem,Integer>>, Integer> iSystMapping; //last Integer is idx of isyst
  output tuple<BackendDAE.StrongComponents, list<tuple<BackendDAE.EqSystem,Integer>>, Integer> oSystMapping; //Map each component to <eqSystem, eqSystemIdx>
protected
  BackendDAE.StrongComponents tmpComps, comps;
  list<tuple<BackendDAE.EqSystem,Integer>> tmpSystMapping;
  Integer currentIdx;
algorithm
  oSystMapping := match(iSyst, iSystMapping)
    case(BackendDAE.EQSYSTEM(matching=BackendDAE.MATCHING(comps=comps)), (tmpComps,tmpSystMapping,currentIdx))
      equation
        //print("--getSystemComponents0 begin\n");
        tmpSystMapping = List.fold2(comps, getSystemComponents1, iSyst, currentIdx, tmpSystMapping);
        //print(stringDelimitList(List.map(comps, BackendDump.printComponent),","));
        tmpComps = listAppend(tmpComps,comps);
        //print("--getSystemComponents0 end (found " + intString(listLength(comps)) + " of " + intString(numberOfElement) + " components)\n");
      then ((tmpComps, tmpSystMapping, currentIdx+1));
    else
      equation
        print("getSystemComponents0 failed");
      then fail();
  end match;
end getSystemComponents0;

protected function getSystemComponents1 "author: marcusw
  Extends the mapping information for the given component and equation system."
  input BackendDAE.StrongComponent icomp;
  input BackendDAE.EqSystem isyst;
  input Integer isystIdx;
  input list<tuple<BackendDAE.EqSystem,Integer>> iMapping; //Map each component to the EqSystem
  output list<tuple<BackendDAE.EqSystem,Integer>> oMapping; //Map each component to the EqSystem
algorithm
  oMapping := listAppend(iMapping,{(isyst,isystIdx)});
end getSystemComponents1;

public function getNumberOfSystemComponents "author: marcusw
  Returns the number of components stored in the BackendDAE."
  input BackendDAE.BackendDAE iDae;
  output Integer oNumOfComps;
protected
  BackendDAE.EqSystems eqs;
algorithm
  BackendDAE.DAE(eqs=eqs) := iDae;
  oNumOfComps := List.fold(eqs, getNumberOfEqSystemComponents, 0);
end getNumberOfSystemComponents;

public function getNumberOfEqSystemComponents "author: marcusw
  Adds the number of components in the given eqSystem to the iNumOfComps."
  input BackendDAE.EqSystem iEqSystem;
  input Integer iNumOfComps;
  output Integer oNumOfComps;
protected
  BackendDAE.StrongComponents comps;
algorithm
  BackendDAE.EQSYSTEM(matching=BackendDAE.MATCHING(comps=comps)) := iEqSystem;
  oNumOfComps := iNumOfComps + listLength(comps);
end getNumberOfEqSystemComponents;

public function getEmptyTaskGraph "generates an empty TaskGraph and empty TaskGraphMeta for a graph with numComps nodes.
author: Waurich TUD 2013-06"
  input Integer numComps;
  input Integer numVars;
  input Integer numEqs;
  output TaskGraph graph;
  output TaskGraphMeta graphData;
protected
  array<list<Integer>> inComps;
  array<tuple<Integer,Integer,Integer>> varCompMapping;
  array<tuple<Integer,Integer,Integer>> eqCompMapping;
  array<String> compNames;
  array<String> compDescs;
  array<tuple<Integer,Real>> exeCosts;
  array<Communications> commCosts;
  array<list<Integer>> compParamMapping;
  array<Integer> nodeMark;
  array<ComponentInfo> compInformations;
algorithm
  graph := arrayCreate(numComps,{});
  inComps := arrayCreate(numComps,{});
  compParamMapping := arrayCreate(numComps,{});
  varCompMapping := arrayCreate(numVars,(0,0,0));
  eqCompMapping := arrayCreate(numEqs,(0,0,0));
  compNames := arrayCreate(numComps,"");
  compDescs :=  arrayCreate(numComps,"");
  exeCosts := arrayCreate(numComps,(-1,-1.0));
  commCosts :=  arrayCreate(numComps,{});
  nodeMark := arrayCreate(numComps,0);
  compInformations := arrayCreate(numComps, COMPONENTINFO(false,false,false));
  graphData := TASKGRAPHMETA(inComps,varCompMapping,eqCompMapping,compParamMapping,compNames,compDescs,exeCosts,commCosts,nodeMark,compInformations);
end getEmptyTaskGraph;

public function copyTaskGraphMeta "copies the metadata to avoid overwriting the arrays.
author: Waurich TUD 2013-07"
  input TaskGraphMeta graphDataIn;
  output TaskGraphMeta graphDataOut;
protected
  array<list<Integer>> inComps, inComps1;
  array<tuple<Integer, Integer, Integer>> varCompMapping, varCompMapping1;
  array<tuple<Integer,Integer,Integer>>  eqCompMapping, eqCompMapping1;
  array<list<Integer>> compParamMapping, compParamMapping1;
  array<String> compNames, compNames1;
  array<String> compDescs, compDescs1;
  array<tuple<Integer,Real>> exeCosts, exeCosts1;
  array<Communications> commCosts, commCosts1;
  array<Integer>nodeMark, nodeMark1;
  array<ComponentInfo> compInformations, compInformations1;
algorithm
  TASKGRAPHMETA(inComps=inComps, varCompMapping=varCompMapping, eqCompMapping=eqCompMapping, compParamMapping=compParamMapping, compNames=compNames, compDescs=compDescs, exeCosts=exeCosts, commCosts=commCosts, nodeMark=nodeMark, compInformations=compInformations) := graphDataIn;
  inComps1 := arrayCopy(inComps);
  varCompMapping1 := arrayCopy(varCompMapping);
  eqCompMapping1 := arrayCopy(eqCompMapping);
  compParamMapping1 := arrayCopy(compParamMapping);
  compNames1 := arrayCopy(compNames);
  compDescs1 :=  arrayCopy(compDescs);
  exeCosts1 := arrayCopy(exeCosts);
  commCosts1 :=  arrayCopy(commCosts);
  nodeMark1 := arrayCopy(nodeMark);
  compInformations1 := arrayCopy(compInformations);
  graphDataOut := TASKGRAPHMETA(inComps1,varCompMapping1,eqCompMapping1,compParamMapping1,compNames1,compDescs1,exeCosts1,commCosts1,nodeMark1,compInformations1);
end copyTaskGraphMeta;

protected function taskGraphAppend "appends a taskGraph system to an other taskGraph system.all indices will be numbered continuously.
author:Waurich TUD 2013-06"
  input TaskGraph graph1In;
  input TaskGraphMeta graphData1In;
  input TaskGraph graph2In;
  input TaskGraphMeta graphData2In;
  output TaskGraph graphOut;
  output TaskGraphMeta graphDataOut;
protected
  Integer eqOffset;
  Integer idxOffset;
  Integer varOffset;
  array<Communications> commCosts1, commCosts2;
  array<list<Integer>> inComps1, inComps2;
  array<tuple<Integer,Integer,Integer>> eqCompMapping1, eqCompMapping2;
  array<tuple<Integer,Real>> exeCosts1, exeCosts2;
  array<Integer> nodeMark1, nodeMark2;
  array<list<Integer>> compParamMapping1, compParamMapping2;
  array<tuple<Integer,Integer,Integer>> varCompMapping1, varCompMapping2; //Map each variable to the scc which solves her
  array<String> compNames1, compNames2;
  array<String> compDescs1, compDescs2;
  array<ComponentInfo> compInformations1, compInformations2;
  TaskGraph graph2;
algorithm
  TASKGRAPHMETA(inComps = inComps1 ,varCompMapping=varCompMapping1, eqCompMapping=eqCompMapping1, compParamMapping=compParamMapping1, compNames=compNames1, compDescs=compDescs1, exeCosts=exeCosts1, commCosts=commCosts1, nodeMark=nodeMark1, compInformations=compInformations1) := graphData1In;
  TASKGRAPHMETA(inComps = inComps2 ,varCompMapping=varCompMapping2, eqCompMapping=eqCompMapping2, compParamMapping=compParamMapping2, compNames=compNames2, compDescs=compDescs2, exeCosts=exeCosts2, commCosts=commCosts2, nodeMark=nodeMark2, compInformations=compInformations2) := graphData2In;
  eqOffset := arrayLength(eqCompMapping1);
  idxOffset := arrayLength(graph1In);
  varOffset := arrayLength(varCompMapping1);
  eqOffset := arrayLength(eqCompMapping1);
  graph2 := Array.map1(graph2In,updateTaskGraphSystem,idxOffset);
  graphOut := arrayAppend(graph1In,graph2);
  inComps2 := Array.map1(inComps2,updateTaskGraphSystem,idxOffset);
  inComps2 := arrayAppend(inComps1,inComps2);
  //varCompMapping2 := Array.map1(varCompMapping2,modifyMapping,varOffset);
  varCompMapping2 := Array.map1(varCompMapping2,modifyMapping,idxOffset);
  varCompMapping2 := arrayAppend(varCompMapping1,varCompMapping2);
  //eqCompMapping2 := Array.map1(eqCompMapping2,modifyMapping,eqOffset);
  eqCompMapping2 := Array.map1(eqCompMapping2,modifyMapping,idxOffset);
  eqCompMapping2 := arrayAppend(eqCompMapping1,eqCompMapping2);
  compParamMapping2 := arrayAppend(compParamMapping1,compParamMapping2);
  compNames2 := Array.map1(compNames2,stringAppend," subsys");  //TODO: change this
  compNames2 := arrayAppend(compNames1,compNames2);
  compDescs2 := arrayAppend(compDescs1,compDescs2);
  exeCosts2 := arrayAppend(exeCosts1,exeCosts2);
  commCosts2 := Array.map1(commCosts2,updateCommCosts,idxOffset);
  commCosts2 := arrayAppend(commCosts1,commCosts2);
  nodeMark2 := arrayAppend(nodeMark1,nodeMark2);
  compInformations2 := arrayAppend(compInformations1, compInformations2);
  graphDataOut := TASKGRAPHMETA(inComps2,varCompMapping2,eqCompMapping2,compParamMapping2,compNames2,compDescs2,exeCosts2,commCosts2,nodeMark2,compInformations2);
end taskGraphAppend;

protected function modifyMapping "author: marcusw,waurich
  Adds the given offset to the first and last tuple-element."
  input tuple<Integer,Integer,Integer> iMappingTuple;
  input Integer iOffset;
  output tuple<Integer,Integer,Integer> oMappingTuple;
protected
  Integer i1,i2,i3; //i1 = offset
algorithm
  (i1,i2,i3) := iMappingTuple;
  oMappingTuple := (i1+iOffset,i2,iOffset);
end modifyMapping;

protected function updateCommCosts "updates the CommCosts to the enumerated indeces.
author: Waurich TUD 2013-07"
  input Communications commCostsIn;
  input Integer idxOffset;
  output Communications commCostsOut;
algorithm
  commCostsOut := List.map1(commCostsIn,updateCommCosts1,idxOffset);
end updateCommCosts;

protected function updateCommCosts1 "adds the idxOffset to the child node index.
author: Waurich TUD 2013-07"
  input Communication commCostsIn;
  input Integer idxOffset;
  output Communication commCostsOut;
protected
  Integer numberOfVars, childNode;
  list<Integer> integerVars,floatVars,booleanVars,stringVars;
  Real requiredTime;
algorithm
  COMMUNICATION(numberOfVars=numberOfVars,integerVars=integerVars,floatVars=floatVars,booleanVars=booleanVars,stringVars=stringVars,childNode=childNode,requiredTime=requiredTime) := commCostsIn;
  childNode := childNode+idxOffset;
  commCostsOut := COMMUNICATION(numberOfVars,integerVars,floatVars,booleanVars,stringVars,childNode,requiredTime);
end updateCommCosts1;

protected function updateTaskGraphSystem "map function to add the indices in the taskGraph system to the number of nodes of the previous system.
author:Waurich TUD 2013-07"
  input list<Integer> graphRowIn;
  input Integer idxOffset;
  output list<Integer> graphRowOut;
algorithm
  graphRowOut := List.map1(graphRowIn,intAdd,idxOffset);
end updateTaskGraphSystem;

protected function createTaskGraph1 "author: marcusw,waurich
  Appends the task-graph information for the given StrongComponent to the given graph."
  input BackendDAE.StrongComponent iComponent;
  input tuple<BackendDAE.IncidenceMatrix,BackendDAE.EqSystem,BackendDAE.Shared,Integer> iSystInfo; //<incidenceMatrix,isyst,iShared,numberOfComponents> in very compact form
  input tuple<array<tuple<Integer,Integer,Integer>>,array<tuple<Integer,Integer,Integer>>,list<Integer>> iVarInfo; //<varCompMapping,eqCompMapping,eventVarLst
  input Boolean iAnalyzeParameters;
  input tuple<TaskGraph,array<list<Integer>>,array<list<Integer>>,array<Communications>,array<String>,array<Integer>,Integer> graphInfoIn;
  //<taskGraph,inComps,compParamMapping,commCosts,compNames,nodeMark,componentIndex>
  output tuple<TaskGraph,array<list<Integer>>,array<list<Integer>>,array<Communications>,array<String>,array<Integer>,Integer> graphInfoOut;
protected
  BackendDAE.IncidenceMatrix incidenceMatrix;
  BackendDAE.EqSystem isyst;
  BackendDAE.Shared ishared;
  BackendDAE.Variables orderedVars;
  BackendDAE.Variables knownVars;
  BackendDAE.EquationArray orderedEqs;
  TaskGraph graphIn;
  TaskGraph graphTmp;
  array<list<Integer>> inComps;
  array<tuple<Integer,Integer,Integer>>  varCompMapping; //<sccIdx, eqSysIdx, offset>
  array<tuple<Integer,Integer,Integer>> eqCompMapping; //<sccIdx, eqSysIdx, offset>
  array<String> compNames;
  array<String> compDescs;
  array<Communications> commCosts;
  Communications commCostsOfNode;
  array<Integer> nodeMark;
  tuple<list<Integer>, list<tuple<Integer, Integer>>, list<Integer>, list<Integer>> unsolvedVars; //<intVarIdc, <floatVarIdx, [0 if derived, 1 if not]>, boolVarIdc,stringVarIdc>
  list<Integer> eventVarLst;
  array<tuple<list<Integer>,list<Integer>,list<Integer>,list<Integer>>> requiredSccs; //required variables <int, float, bool, string>
  Integer componentIndex, numberOfComps;
  list<tuple<Integer,list<Integer>,list<Integer>,list<Integer>,list<Integer>>> requiredSccs_RefCount; //<sccIdx, refCountInt, refCountFloat, refCountBool, refCountString>
  String compName;
  list<Integer> paramVars;
  array<list<Integer>> compParamMapping;
algorithm
  (incidenceMatrix,isyst,ishared,numberOfComps) := iSystInfo;
  BackendDAE.SHARED(knownVars=knownVars) := ishared;
  BackendDAE.EQSYSTEM(orderedVars=orderedVars,orderedEqs=orderedEqs) := isyst;
  (varCompMapping,eqCompMapping,eventVarLst) := iVarInfo;
  (graphIn,inComps,compParamMapping,commCosts,compNames,nodeMark,componentIndex) := graphInfoIn;
  inComps := arrayUpdate(inComps,componentIndex,{componentIndex});
  compName := BackendDump.strongComponentString(iComponent);
  compNames := arrayUpdate(compNames,componentIndex,compName);
  _ := HpcOmBenchmark.benchSystem();

  (unsolvedVars,paramVars) := getUnsolvedVarsBySCC(iComponent,incidenceMatrix,orderedVars,knownVars,orderedEqs,eventVarLst,iAnalyzeParameters);
  compParamMapping := arrayUpdate(compParamMapping, componentIndex, paramVars);
  requiredSccs := arrayCreate(numberOfComps,({},{},{},{})); //create a ref-counter for each component
  requiredSccs := List.fold2(List.map1(Util.tuple41(unsolvedVars),Util.makeTuple,1),fillSccList,1,varCompMapping,requiredSccs);
  requiredSccs := List.fold2(Util.tuple42(unsolvedVars),fillSccList,2,varCompMapping,requiredSccs);
  requiredSccs := List.fold2(List.map1(Util.tuple43(unsolvedVars),Util.makeTuple,1),fillSccList,3,varCompMapping,requiredSccs);
  requiredSccs := List.fold2(List.map1(Util.tuple44(unsolvedVars),Util.makeTuple,1),fillSccList,4,varCompMapping,requiredSccs);
  ((_,requiredSccs_RefCount)) := Array.fold(requiredSccs, convertRefArrayToList, (1,{}));
  (commCosts,commCostsOfNode) := updateCommCostBySccRef(requiredSccs_RefCount, componentIndex, commCosts);
  graphTmp := fillAdjacencyList(graphIn,componentIndex,commCostsOfNode,1);
  graphTmp := Array.map1(graphTmp,List.sort,intGt);
  graphInfoOut := (graphTmp,inComps,compParamMapping,commCosts,compNames,nodeMark,componentIndex+1);
end createTaskGraph1;

protected function updateCommCostBySccRef "author: marcusw
  Updates the given commCosts-array with the values of the refCount-list."
  input list<tuple<Integer,list<Integer>,list<Integer>,list<Integer>,list<Integer>>> requiredSccs_RefCount; //<sccIdx,refCountInt,refCountFloat,refCountBool,refCountString>
  input Integer nodeIdx;
  input array<Communications> iCommCosts;
  output array<Communications> oCommCosts;
  //the communications, created for the given node (nodeIdx) - the required time is set to -1.0, the childNode-idx is set the the parent-idx of the ref counter!
  output Communications oNodeComms;
protected
  Communications tmpComms;
algorithm
  tmpComms := List.map1(requiredSccs_RefCount, createCommunicationObject, -1.0);
  oCommCosts := List.fold1(tmpComms,updateCommCostBySccRef1,nodeIdx,iCommCosts);
  oNodeComms := tmpComms;
end updateCommCostBySccRef;

protected function createCommunicationObject "author: marcusw
  Helper function which converts a tuple<sccIdx,refCountInt,refCountFloat,refCountBool> to a Communictaion-object."
  input tuple<Integer,list<Integer>,list<Integer>,list<Integer>,list<Integer>> iTuple;
  input Real requiredTime;
  output Communication oComm;
protected
  list<Integer> integerVars,floatVars,booleanVars,stringVars;
  Integer sccIdx,refCountSum;
algorithm
  (sccIdx,integerVars,floatVars,booleanVars,stringVars) := iTuple;
  refCountSum := listLength(integerVars) + listLength(floatVars) + listLength(booleanVars) + listLength(stringVars);
  oComm := COMMUNICATION(refCountSum,integerVars,floatVars,booleanVars,stringVars,sccIdx,requiredTime);
end createCommunicationObject;

protected function updateCommCostBySccRef1 "author: marcusw
  Helper function which appends an edge from source to target with the given parameters."
  input Communication iEdgeSource;
  input Integer iEdgeTarget; //sccIdx
  input array<Communications> iCommCosts; //<sccIdx,numberOfVars,requiredCycles>
  output array<Communications> oCommCosts;
protected
  Communications oldComms;
  Integer sourceSccIdx;
  list<Integer> integerVars,floatVars,booleanVars,stringVars;
  Integer numberOfVars;
  Real requiredTime;
  Communication tmpComm;
algorithm
  COMMUNICATION(numberOfVars=numberOfVars,integerVars=integerVars,floatVars=floatVars,booleanVars=booleanVars,stringVars=stringVars,childNode=sourceSccIdx,requiredTime=requiredTime) := iEdgeSource;
  oldComms := arrayGet(iCommCosts, sourceSccIdx);
  //print("updateCommCostBySccRef1 added edge from " + intString(sourceSccIdx) + " to " + intString(iEdgeTarget) + "\n");
  tmpComm := COMMUNICATION(numberOfVars,integerVars,floatVars,booleanVars,stringVars,iEdgeTarget,requiredTime);
  oCommCosts := arrayUpdate(iCommCosts, sourceSccIdx, tmpComm::oldComms);
end updateCommCostBySccRef1;

protected function fillAdjacencyList "append the child index to the rows indexed by the parent list.
author: waurich TUD 2013-06"
  input array<list<Integer>> adjLstIn;
  input Integer childNode;
  input Communications parentLst; //Communication-objects, with childNode = parentNodeIdx
  input Integer Idx; //current parent, starting with 1
  output array<list<Integer>> adjLstOut;
algorithm
  adjLstOut := matchcontinue(adjLstIn,childNode,parentLst,Idx)
    local
      Communication parentNode;
      list<Integer> parentRow;
      array<list<Integer>> adjLst;
      Integer parentNodeIdx;
    case(_,_,_,_)
      equation
        true = listLength(parentLst) >= Idx;
        parentNode = listGet(parentLst,Idx);
        COMMUNICATION(childNode=parentNodeIdx) = parentNode;
        parentRow = arrayGet(adjLstIn,parentNodeIdx);
        parentRow = childNode::parentRow;
        parentRow = List.removeOnTrue(parentNodeIdx,intEq,parentRow);  // deletes the self-loops
        adjLst = arrayUpdate(adjLstIn,parentNodeIdx,parentRow);
        adjLst = fillAdjacencyList(adjLst,childNode,parentLst,Idx+1);
      then
        adjLst;
    else adjLstIn;
  end matchcontinue;
end fillAdjacencyList;

protected function getEquationStrings "gets the equation and the variable its solved for for every StrongComponent. index = component. entry = description
author:Waurich TUD 2013-06"
  input BackendDAE.StrongComponents iComps;
  input BackendDAE.EqSystem iEqSystem;
  output array<String> eqDescsOut;
protected
  list<String> eqDescs;
algorithm
  eqDescs := List.fold1(iComps,getEquationStrings2,iEqSystem,{});
  eqDescs := listReverse(eqDescs);
  eqDescsOut := listArray(eqDescs);
end getEquationStrings;

protected function getEquationStrings2 "implementation for getEquationStrings
author:Waurich TUD 2013-06"
  input BackendDAE.StrongComponent comp;
  input BackendDAE.EqSystem iEqSystem;
  input List<String> iEqDesc;
  output List<String> oEqDesc;
algorithm
  oEqDesc := matchcontinue(comp,iEqSystem,iEqDesc)
    local
      Integer i;
      Integer v;
      List<BackendDAE.Equation> eqnLst;
      List<BackendDAE.Var> varLst;
      array<Integer> ass2;
      List<Integer> es;
      List<Integer> vs;
      List<String> descLst;
      List<String> eqDescLst;
      List<String> varDescLst;
      String eqString;
      String varString;
      String desc;
      Option<list<tuple<Integer, Integer, BackendDAE.Equation>>> jac;
      BackendDAE.JacobianType jacT;
      BackendDAE.EquationArray orderedEqs;
      BackendDAE.Variables orderedVars;
      BackendDAE.Equation eqn;
      BackendDAE.Var var;
    case(BackendDAE.SINGLEEQUATION(eqn = i, var = v), BackendDAE.EQSYSTEM(orderedEqs = orderedEqs, orderedVars = orderedVars),_)
      equation
       //get the equation string
       eqnLst = BackendEquation.equationList(orderedEqs);
       eqn = listGet(eqnLst,i);
       eqString = BackendDump.equationString(eqn);
       //get the variable string
       varLst = BackendVariable.varList(orderedVars);
       var = listGet(varLst,v);
       varString = getVarString(var);
       desc = (eqString + " FOR " + varString);
       descLst = desc::iEqDesc;
     then
       descLst;
  case(BackendDAE.EQUATIONSYSTEM(jac = BackendDAE.FULL_JACOBIAN(_)), BackendDAE.EQSYSTEM(orderedEqs = orderedEqs),_)
     equation
       _ = BackendEquation.equationList(orderedEqs);
       desc = ("Equation System");
       descLst = desc::iEqDesc;
     then
       descLst;
   case(BackendDAE.SINGLEARRAY(eqn = i, vars = vs), BackendDAE.EQSYSTEM(orderedEqs = orderedEqs, orderedVars = orderedVars, matching= BackendDAE.MATCHING()),_)
     equation
      //get the equation string
      eqnLst = BackendEquation.equationList(orderedEqs);
      eqn = listGet(eqnLst,i);
      eqString = BackendDump.equationString(eqn);
      //get the variable string
      varLst = BackendVariable.varList(orderedVars);
      //var = listGet(varLst,arrayGet(ass2,i));
      //varString = getVarString(var);
      //desc = ("ARRAY:"+eqString + " FOR " + varString);
      desc = ("ARRAY:"+eqString + " FOR THE VARS: " + stringDelimitList(List.map1(vs,List.getIndexFirst,List.map(varLst,getVarString))," AND "));
      descLst = desc::iEqDesc;
    then
      descLst;
   case(BackendDAE.SINGLEALGORITHM(eqn = i, vars = vs), BackendDAE.EQSYSTEM(orderedEqs = orderedEqs, orderedVars = orderedVars, matching= BackendDAE.MATCHING()),_)
     equation
      //get the equation string
      eqnLst = BackendEquation.equationList(orderedEqs);
      eqn = listGet(eqnLst,i);
      eqString = BackendDump.equationString(eqn);
      //get the variable string
      varLst = BackendVariable.varList(orderedVars);
      //var = listGet(varLst,arrayGet(ass2,i));
      //varString = getVarString(var);
      //desc = ("ALGO:"+eqString + " FOR " + varString);
      desc = ("ALGO: "+eqString + " FOR THE VARS: " + stringDelimitList(List.map1(vs,List.getIndexFirst,List.map(varLst,getVarString))," AND "));
      descLst = desc::iEqDesc;
    then
      descLst;
   case(BackendDAE.SINGLECOMPLEXEQUATION(eqn = i, vars = vs), BackendDAE.EQSYSTEM(orderedEqs = orderedEqs, orderedVars = orderedVars, matching= BackendDAE.MATCHING()),_)
     equation
      //get the equation string
      eqnLst = BackendEquation.equationList(orderedEqs);
      eqn = listGet(eqnLst,i);
      eqString = BackendDump.equationString(eqn);
      //get the variable string
      varLst = BackendVariable.varList(orderedVars);
      //var = listGet(varLst,arrayGet(ass2,i));
      //varString = getVarString(var);
      //desc = ("COMPLEX:"+eqString + " FOR " + varString);
      desc = ("COMPLEX: "+eqString + " FOR THE VARS: " + stringDelimitList(List.map1(vs,List.getIndexFirst,List.map(varLst,getVarString))," AND "));
      descLst = desc::iEqDesc;
    then
      descLst;
   case(BackendDAE.SINGLEWHENEQUATION(eqn = i, vars = vs), BackendDAE.EQSYSTEM(orderedEqs = orderedEqs, orderedVars = orderedVars, matching= BackendDAE.MATCHING()),_)
     equation
      //get the equation string
      eqnLst = BackendEquation.equationList(orderedEqs);
      eqn = listGet(eqnLst,i);
      eqString = BackendDump.equationString(eqn);
      //get the variable string
      varLst = BackendVariable.varList(orderedVars);
      //var = listGet(varLst,arrayGet(ass2,i));
      //varString = getVarString(var);
      //desc = ("WHEN:"+eqString + " FOR " + varString);
      desc = ("WHEN:"+eqString + " FOR THE VARS: " + stringDelimitList(List.map1(vs,List.getIndexFirst,List.map(varLst,getVarString))," AND "));
      descLst = desc::iEqDesc;
    then
      descLst;
   case(BackendDAE.SINGLEIFEQUATION(eqn = i, vars = vs), BackendDAE.EQSYSTEM(orderedEqs = orderedEqs, orderedVars = orderedVars, matching= BackendDAE.MATCHING()),_)
     equation
      //get the equation string
      eqnLst = BackendEquation.equationList(orderedEqs);
      eqn = listGet(eqnLst,i);
      eqString = BackendDump.equationString(eqn);
      //get the variable string
      varLst = BackendVariable.varList(orderedVars);
      //var = listGet(varLst,arrayGet(ass2,i));
      //varString = getVarString(var);
      //desc = ("IFEQ:"+eqString + " FOR " + varString);
      desc = ("IFEQ:"+eqString + " FOR THE VARS: " + stringDelimitList(List.map1(vs,List.getIndexFirst,List.map(varLst,getVarString))," AND "));
      descLst = desc::iEqDesc;
    then
      descLst;
  case(BackendDAE.TORNSYSTEM(linear=true), BackendDAE.EQSYSTEM(orderedEqs = orderedEqs,  matching= BackendDAE.MATCHING()),_)
     equation
      //get the equation string
       _ = BackendEquation.equationList(orderedEqs);
       desc = ("Torn linear System");
       descLst = desc::iEqDesc;
    then
      descLst;
  case(BackendDAE.TORNSYSTEM(linear=false), BackendDAE.EQSYSTEM(orderedEqs = orderedEqs,  matching= BackendDAE.MATCHING()),_)
     equation
      //get the equation string
       _ = BackendEquation.equationList(orderedEqs);
       desc = ("Torn nonlinear System");
       descLst = desc::iEqDesc;
    then
      descLst;
  else
    equation
      desc = ("no singleEquation");
      descLst = desc::iEqDesc;
    then
      descLst;
  end matchcontinue;
end getEquationStrings2;

public function getVarString "get the var string for a given variable. shortens the String. if necessary insert der operator
author:waurich TUD 2013-06"
  input BackendDAE.Var inVar;
  output String varString;
algorithm
  varString := matchcontinue(inVar)
  local
    BackendDAE.VarKind kind;
    list<String> varDescLst;
  case(_)
    equation
    true = BackendVariable.isNonStateVar(inVar);
    varString = BackendDump.varString(inVar);
    varDescLst = stringListStringChar(varString);
    varDescLst = shortenVarString(varDescLst);
    varString = stringCharListString(varDescLst);
  then
    varString;
  case(_)
    equation
    false = BackendVariable.isNonStateVar(inVar);
    varString = BackendDump.varString(inVar);
    varDescLst = stringListStringChar(varString);
    varDescLst = shortenVarString(varDescLst);
    varString = stringCharListString(varDescLst);
    varString = (" der(" + varString + ")");
    then
      varString;
  end matchcontinue;
end getVarString;

public function shortenVarString " terminates var string at :
author:Waurich TUD 2013-06"
  input List<String> iString;
  output List<String> oString;
protected
  Integer pos;
algorithm
  pos := List.position(":",iString)-1;
  (oString,_) := List.split(iString,pos);
end shortenVarString;

protected function getEventNodes " gets the taskgraph nodes that are when-equations
author:Waurich TUD 2013-06"
  input BackendDAE.BackendDAE systIn;
  input array<tuple<Integer,Integer,Integer>> eqCompMapping;
  output list<Integer> eventNodes;
protected
  list<Integer> eqLst;
  list<tuple<Integer,Integer,Integer>> tplLst;
  BackendDAE.EqSystems systemsIn;
algorithm
  BackendDAE.DAE(eqs=systemsIn) := systIn;
  ((eqLst,_)) := List.fold(systemsIn, getEventNodeEqs,({},0));
  eventNodes := getArrayTuple31(eqLst,eqCompMapping);
end getEventNodes;

protected function getEventNodeEqs "gets the equation for the When-nodes.
author: Waurich TUD 2013-06"
  input BackendDAE.EqSystem systIn;
  input tuple<list<Integer>,Integer> eventInfoIn;
  output tuple<list<Integer>,Integer> eventInfoOut;
protected
  BackendDAE.StrongComponents comps;
  list<Integer> eventEqs;
  list<Integer> eventEqsIn;
  Integer numOfEqs;
  Integer offset;
algorithm
  BackendDAE.EQSYSTEM(orderedEqs = BackendDAE.EQUATION_ARRAY(numberOfElement=numOfEqs),matching=BackendDAE.MATCHING(comps = comps)) := systIn;
  (eventEqsIn,offset) := eventInfoIn;
  eventEqs := getEventNodeEqs1(comps,offset,{});
  offset := offset+numOfEqs;
  eventEqs := listAppend(eventEqs,eventEqsIn);
  eventInfoOut := (eventEqs,offset);
end getEventNodeEqs;

protected function getEventNodeEqs1 "fold-function for getEventNodeEqs to compute the when equation in an eqSystem
author: Waurich TUD 2013-06"
  input BackendDAE.StrongComponents comps;
  input Integer offset;
  input list<Integer> eventEqsIn;
  output list<Integer> eventEqsOut;
algorithm
  eventEqsOut := matchcontinue(comps,offset,eventEqsIn)
    local
      Integer eqn;
      Integer sysCount;
      list<Integer> eventEqs;
      list<Integer> condVars;
      BackendDAE.StrongComponents rest;
      BackendDAE.StrongComponent head;
    case((head::rest),_,_)
      equation
        true = isWhenEquation(head);
        BackendDAE.SINGLEWHENEQUATION(eqn = eqn) = head;
        eqn = eqn+offset;
        eventEqs = getEventNodeEqs1(rest,offset,eqn::eventEqsIn);
      then
        eventEqs;
    case((head::rest),_,_)
      equation
        false = isWhenEquation(head);
        eventEqs = getEventNodeEqs1(rest,offset,eventEqsIn);
      then
        eventEqs;
    case({},_,_)
      then
        eventEqsIn;
  end matchcontinue;
end getEventNodeEqs1;

protected function getArrayTuple31 "matches entries of list1 with the assigned values of assign to obtain the values
author:Waurich TUD 2013-06"
  input list<Integer> list1;
  input array<tuple<Integer,Integer,Integer>> assign;
  output list<Integer> list2Out;
protected
  list<tuple<Integer,Integer,Integer>> tplLst;
algorithm
   tplLst := List.map1(list1,Array.getIndexFirst,assign);
   list2Out := List.map(tplLst,Util.tuple31);
end getArrayTuple31;

protected function isWhenEquation "checks if the comp is of type SINGLEWHENEQUATION.
author:Waurich TUD 2013-06"
  input BackendDAE.StrongComponent inComp;
  output Boolean isWhenEq;
algorithm
  isWhenEq := matchcontinue(inComp)
  local Integer eqn;
    case(BackendDAE.SINGLEWHENEQUATION())
    then
      true;
  else false;
  end matchcontinue;
end isWhenEquation;

protected function fillSccList "author: marcusw
  This function appends the scc, which solves the given variable, to the requiredsccs-list."
  input tuple<Integer,Integer> iVariable; //<varIdx, [derived = 0, not derived = 1]>
  input Integer iVarType; //<1 = int, 2 = float, 3 = bool, 4 = string>
  input array<tuple<Integer,Integer,Integer>> iVarCompMapping; //<sccIdx, eqSysIdx, offset>
  input array<tuple<list<Integer>,list<Integer>,list<Integer>,list<Integer>>> iRequiredSccs; //<int vars, float vars, bool vars>
  output array<tuple<list<Integer>,list<Integer>,list<Integer>,list<Integer>>> oRequiredSccs;
algorithm
  oRequiredSccs := match(iVariable,iVarType,iVarCompMapping,iRequiredSccs)
    local
      Integer varIdx, sccIdx;
      list<Integer> integerVars,floatVars,booleanVars,stringVars;
      array<tuple<list<Integer>,list<Integer>,list<Integer>,list<Integer>>> tmpRequiredSccs;
    case ((varIdx,1),1,_,tmpRequiredSccs)
      equation
        ((sccIdx,_,_)) = arrayGet(iVarCompMapping,varIdx);
        ((integerVars,floatVars,booleanVars,stringVars)) = arrayGet(iRequiredSccs, sccIdx);
        integerVars = varIdx::integerVars;
        tmpRequiredSccs = arrayUpdate(tmpRequiredSccs,sccIdx,(integerVars,floatVars,booleanVars,stringVars));
      then tmpRequiredSccs;
    case ((varIdx,1),2,_,tmpRequiredSccs)
      equation
        ((sccIdx,_,_)) = arrayGet(iVarCompMapping,varIdx);
        ((integerVars,floatVars,booleanVars,stringVars)) = arrayGet(iRequiredSccs, sccIdx);
        floatVars = varIdx::floatVars;
        tmpRequiredSccs = arrayUpdate(tmpRequiredSccs,sccIdx,(integerVars,floatVars,booleanVars,stringVars));
      then tmpRequiredSccs;
    case ((varIdx,1),3,_,tmpRequiredSccs)
      equation
        ((sccIdx,_,_)) = arrayGet(iVarCompMapping,varIdx);
        ((integerVars,floatVars,booleanVars,stringVars)) = arrayGet(iRequiredSccs, sccIdx);
        booleanVars = varIdx::booleanVars;
        tmpRequiredSccs = arrayUpdate(tmpRequiredSccs,sccIdx,(integerVars,floatVars,booleanVars,stringVars));
      then tmpRequiredSccs;
    case ((varIdx,1),4,_,tmpRequiredSccs)
      equation
        ((sccIdx,_,_)) = arrayGet(iVarCompMapping,varIdx);
        ((integerVars,floatVars,booleanVars,stringVars)) = arrayGet(iRequiredSccs, sccIdx);
        stringVars = varIdx::stringVars;
        tmpRequiredSccs = arrayUpdate(tmpRequiredSccs,sccIdx,(integerVars,floatVars,booleanVars,stringVars));
      then tmpRequiredSccs;
   else iRequiredSccs;
  end match;
end fillSccList;

protected function convertRefArrayToList "author: marcusw
  Append the reference values for the given scc to the result list, if the reference counter is not zero."
  input tuple<list<Integer>,list<Integer>,list<Integer>,list<Integer>> iRefCountValues; //<referenceInt, referenceFloat, referenceBool,referenceString>
  input tuple<Integer,list<tuple<Integer,list<Integer>,list<Integer>,list<Integer>,list<Integer>>>> iList; //the current index and the current ref-list (<sccIdx, refCountInt, refCountFloat, refCountBool, refCountString>)
  output tuple<Integer,list<tuple<Integer,list<Integer>,list<Integer>,list<Integer>,list<Integer>>>> oList;
protected
  Integer curIdx;
  list<Integer> integerVars,floatVars,booleanVars,stringVars;
  tuple<Integer,list<Integer>,list<Integer>,list<Integer>,list<Integer>> tmpTuple;
  list<tuple<Integer,list<Integer>,list<Integer>,list<Integer>,list<Integer>>> curList;
algorithm
  oList := match(iRefCountValues,iList)
    case(({},{},{},{}),(curIdx,curList))
      then ((curIdx+1,curList));
    case((integerVars,floatVars,booleanVars,stringVars),(curIdx,curList))
      equation
        tmpTuple = (curIdx,integerVars,floatVars,booleanVars,stringVars);
        curList = tmpTuple::curList;
      then ((curIdx+1,curList));
   end match;
end convertRefArrayToList;

protected function getUnsolvedVarsBySCC "author: marcusw,waurich
  Returns all required variables which are not solved inside the given component."
  input BackendDAE.StrongComponent iComponent;
  input BackendDAE.IncidenceMatrix iIncidenceMatrix;
  input BackendDAE.Variables iOrderedVars;
  input BackendDAE.Variables iKnownVars; //parameters and constants of SHARED-object
  input BackendDAE.EquationArray iOrderedEquations;
  input list<Integer> iEventVarLst;
  input Boolean iAnalyzeParameters;
  output tuple<list<Integer>,list<tuple<Integer,Integer>>,list<Integer>,list<Integer>> oUnsolvedVars; //<intVarIdc, <floatVarIdx, [0 if derived, 1 if not]>, boolVarIdc, stringVarIdc>
  output list<Integer> oParamVars; //indices related to iKnownVars-object
algorithm
  (oUnsolvedVars, oParamVars) := matchcontinue(iComponent, iIncidenceMatrix, iOrderedVars, iKnownVars, iOrderedEquations, iEventVarLst, iAnalyzeParameters)
    local
      Integer varIdx;
      list<Integer> varIdc;
      tuple<list<Integer>,list<tuple<Integer,Integer>>,list<Integer>,list<Integer>> tmpVars;
      list<Integer> paramVars;
    case(BackendDAE.SINGLEEQUATION(var=varIdx),_,_,_,_,_,_)
      equation
        (tmpVars, paramVars) = getUnsolvedVarsBySCC0(iComponent,iIncidenceMatrix,iOrderedVars,iKnownVars,iOrderedEquations,{varIdx},iEventVarLst, iAnalyzeParameters);
      then
        (tmpVars, paramVars);
    case(BackendDAE.EQUATIONSYSTEM(vars=varIdc),_,_,_,_,_,_)
      equation
        (tmpVars, paramVars) = getUnsolvedVarsBySCC0(iComponent,iIncidenceMatrix,iOrderedVars,iKnownVars,iOrderedEquations,varIdc,iEventVarLst, iAnalyzeParameters);
      then
        (tmpVars, paramVars);
    case(BackendDAE.SINGLEARRAY(vars=varIdc),_,_,_,_,_,_)
      equation
        (tmpVars, paramVars) = getUnsolvedVarsBySCC0(iComponent,iIncidenceMatrix,iOrderedVars,iKnownVars,iOrderedEquations,varIdc,iEventVarLst, iAnalyzeParameters);
      then
        (tmpVars, paramVars);
    case(BackendDAE.SINGLEALGORITHM(vars=varIdc),_,_,_,_,_,_)
      equation
        (tmpVars, paramVars) = getUnsolvedVarsBySCC0(iComponent,iIncidenceMatrix,iOrderedVars,iKnownVars,iOrderedEquations,varIdc,iEventVarLst, iAnalyzeParameters);
      then
        (tmpVars, paramVars);
    case(BackendDAE.SINGLECOMPLEXEQUATION(vars=varIdc),_,_,_,_,_,_)
      equation
        (tmpVars, paramVars) = getUnsolvedVarsBySCC0(iComponent,iIncidenceMatrix,iOrderedVars,iKnownVars,iOrderedEquations,varIdc,iEventVarLst, iAnalyzeParameters);
      then (tmpVars, paramVars);
    case(BackendDAE.SINGLEWHENEQUATION(vars=varIdc),_,_,_,_,_,_)
      equation
        (tmpVars, paramVars) = getUnsolvedVarsBySCC0(iComponent,iIncidenceMatrix,iOrderedVars,iKnownVars,iOrderedEquations,varIdc,iEventVarLst, iAnalyzeParameters);
      then (tmpVars, paramVars);
    case(BackendDAE.SINGLEIFEQUATION(vars=varIdc),_,_,_,_,_,_)
      equation
        (tmpVars, paramVars) = getUnsolvedVarsBySCC0(iComponent,iIncidenceMatrix,iOrderedVars,iKnownVars,iOrderedEquations,varIdc,iEventVarLst, iAnalyzeParameters);
      then
        (tmpVars, paramVars);
    case(BackendDAE.TORNSYSTEM(tearingvars=varIdc),_,_,_,_,_,_)
      equation
        (tmpVars, paramVars) = getUnsolvedVarsBySCC0(iComponent,iIncidenceMatrix,iOrderedVars,iKnownVars,iOrderedEquations,varIdc,iEventVarLst, iAnalyzeParameters);
      then
        (tmpVars, paramVars);
    else
      equation
        print("getUnsolvedVarsBySCC failed\n");
        then fail();
   end matchcontinue;
end getUnsolvedVarsBySCC;

protected function getUnsolvedVarsBySCC0 "author: marcusw
  Returns all required variables which are not solved inside the given component."
  input BackendDAE.StrongComponent iComponent;
  input BackendDAE.IncidenceMatrix iIncidenceMatrix;
  input BackendDAE.Variables iOrderedVars;
  input BackendDAE.Variables iKnownVars; //parameters and constants of SHARED-object
  input BackendDAE.EquationArray iOrderedEquations;
  input list<Integer> iVarIdc; //variables that are solved by the component
  input list<Integer> iEventVarLst;
  input Boolean iAnalyzeParameters;
  output tuple<list<Integer>,list<tuple<Integer,Integer>>,list<Integer>,list<Integer>> oUnsolvedVars; //<intVars, <floatVarIdx, [1 if derived, 0 if not]>, boolVars, stringVars>
  output list<Integer> oParamVars; //indices related to iKnownVars-object
protected
  list<tuple<Integer,Integer>> tmpVars;
algorithm
  (tmpVars,oParamVars) := getVarsBySCC(iComponent, iIncidenceMatrix, iOrderedVars, iKnownVars, iOrderedEquations, iAnalyzeParameters);
  tmpVars := List.filter1OnTrue(tmpVars, isTupleMember, iVarIdc);
  tmpVars := removeEventVars(iEventVarLst,tmpVars,1);
  oUnsolvedVars := List.fold1(tmpVars, getUnsolvedVarsBySCC1, iOrderedVars, ({},{},{},{}));
end getUnsolvedVarsBySCC0;

protected function getUnsolvedVarsBySCC1 "author: marcusw
  Append the given variable, regarding their type, to the list of required variables."
  input tuple<Integer,Integer> iVarIdx; //<varIdx, derived[0] | not derived [1]>
  input BackendDAE.Variables orderedVars;
  input tuple<list<Integer>,list<tuple<Integer,Integer>>,list<Integer>,list<Integer>> iUnsolvedVars; //<intVarIdc,realVarIdc,boolVarIdc,stringVarIdc>
  output tuple<list<Integer>,list<tuple<Integer,Integer>>,list<Integer>,list<Integer>> oUnsolvedVars;
protected
  BackendDAE.Var var;
  BackendDAE.Type varType;
algorithm
  var := BackendVariable.getVarAt(orderedVars, Util.tuple21(iVarIdx));
  varType := BackendVariable.getVarType(var);
  oUnsolvedVars := getUnsolvedVarsBySCC2(varType, iVarIdx, iUnsolvedVars);
end getUnsolvedVarsBySCC1;

protected function getUnsolvedVarsBySCC2 "author: marcusw
  Append the given variable, regarding their type, to the list of required variables."
  input DAE.Type iVarType;
  input tuple<Integer,Integer> iVarIdx;
  input tuple<list<Integer>,list<tuple<Integer,Integer>>,list<Integer>,list<Integer>> iUnsolvedVars; //<intVarIdc,realVarIdc,boolVarIdc,stringVarIdc>
  output tuple<list<Integer>,list<tuple<Integer,Integer>>,list<Integer>,list<Integer>> oUnsolvedVars;
protected
  list<Integer> intVarIdc,boolVarIdc,stringVarIdc;
  list<tuple<Integer,Integer>> realVarIdc;
  Integer varIdx, derived;
  DAE.Type ty;
algorithm
  oUnsolvedVars := match(iVarType, iVarIdx, iUnsolvedVars)
    case(DAE.T_INTEGER(_,_),(varIdx,derived),(intVarIdc,realVarIdc,boolVarIdc,stringVarIdc))
      equation
        intVarIdc = varIdx::intVarIdc;
      then ((intVarIdc,realVarIdc,boolVarIdc,stringVarIdc));
    case(DAE.T_REAL(_,_),(varIdx,derived),(intVarIdc,realVarIdc,boolVarIdc,stringVarIdc))
      equation
        realVarIdc = (varIdx,derived)::realVarIdc;
      then ((intVarIdc,realVarIdc,boolVarIdc,stringVarIdc));
    case(DAE.T_BOOL(_,_),(varIdx,derived),(intVarIdc,realVarIdc,boolVarIdc,stringVarIdc))
      equation
        boolVarIdc = varIdx::boolVarIdc;
      then ((intVarIdc,realVarIdc,boolVarIdc,stringVarIdc));
    case(DAE.T_ARRAY(ty=ty),(varIdx,derived),(intVarIdc,realVarIdc,boolVarIdc,stringVarIdc))
      then getUnsolvedVarsBySCC2(ty,iVarIdx,iUnsolvedVars);
    case(DAE.T_ENUMERATION(),(varIdx,derived),(intVarIdc,realVarIdc,boolVarIdc,stringVarIdc))
      equation
        stringVarIdc = varIdx::stringVarIdc;
      then ((intVarIdc,realVarIdc,boolVarIdc,stringVarIdc));
    case(DAE.T_STRING(_,_),(varIdx,derived),(intVarIdc,realVarIdc,boolVarIdc,stringVarIdc))
      equation
        stringVarIdc = varIdx::stringVarIdc;
      then ((intVarIdc,realVarIdc,boolVarIdc,stringVarIdc));
    else
      equation
        print("getUnsolvedVarsBySCC2: Warning, unknown varType for variable " + intString(Util.tuple21(iVarIdx)) +" !\n");
     then iUnsolvedVars;
  end match;
end getUnsolvedVarsBySCC2;

protected function removeEventVars "removes EventVars from the varList.
author:Waurich TUD 2013-06"
  input list<Integer> eventVarLst;
  input list<tuple<Integer,Integer>> varLstIn;
  input Integer varIdx;
  output list<tuple<Integer,Integer>> varLstOut;
algorithm
  varLstOut := matchcontinue(eventVarLst,varLstIn,varIdx)
    local
      tuple<Integer,Integer> varTpl;
      list<tuple<Integer,Integer>> rest;
      list<tuple<Integer,Integer>> varLst;
      Integer var;
    case(_,_,_)
      equation
        true = intLe(varIdx,listLength(varLstIn));
        varTpl = listGet(varLstIn,varIdx);
        (var,_) = varTpl;
        true = List.isMemberOnTrue(var,eventVarLst,intEq);
        varLst = listDelete(varLstIn,varIdx);
        varLst = removeEventVars(eventVarLst,varLst,varIdx);
      then
        varLst;
    case(_,_,_)
      equation
        true = intLe(varIdx,listLength(varLstIn));
        varTpl = listGet(varLstIn,varIdx);
        (var,_) = varTpl;
        false = List.isMemberOnTrue(var,eventVarLst,intEq);
        varLst = removeEventVars(eventVarLst,varLstIn,varIdx+1);
      then
        varLst;
    else varLstIn;
  end matchcontinue;
end removeEventVars;

protected function isTupleMember "author: marcusw
  Checks if the given variable (stored as tuple <id,state>) is part of the variable-list. This is only possible if the
  second tuple-argument is one - this means that the variable is not derived."
  input tuple<Integer,Integer> inTuple;
  input List<Integer> varIdc;
  output Boolean isNotMember;
protected
  Integer varIdx, varState;
  Boolean returnValue;
algorithm
  isNotMember := matchcontinue(inTuple, varIdc)
    case((varIdx,varState), _)
      equation
        true = intGt(varIdx,0);
        true = intEq(varState,1);
        returnValue = List.isMemberOnTrue(varIdx, varIdc, intEq);
      then not returnValue;
    else true;
  end matchcontinue;
end isTupleMember;

protected function compareTupleByVarIdx "author: marcusw
  Checks if the given varIdx is the same as the first tuple-argument."
  input Integer varIdx;
  input tuple<Integer,Integer> var2Idx;
  output Boolean equal;
algorithm
  equal := intEq(Util.tuple21(var2Idx),varIdx);
end compareTupleByVarIdx;

public function compareTasksByExecTime "author: marcusw
  Compares two given tasks regarding their execution costs."
  input Integer iTask1;
  input Integer iTask2;
  input  array<list<Integer>> iTaskComps;
  input array<tuple<Integer, Real>> iExeCosts;
  output Boolean oResult;
protected
  Real exeCosts1, exeCosts2;
  list<Integer> taskComps1, taskComps2;
algorithm
  taskComps1 := arrayGet(iTaskComps, iTask1);
  taskComps2 := arrayGet(iTaskComps, iTask2);
  exeCosts1 := addUpExeCostsForNode(taskComps1, iExeCosts, 0.0);
  exeCosts2 := addUpExeCostsForNode(taskComps2, iExeCosts, 0.0);
  //print("compareTasksByExecTime: Task '" + intString(iTask1) + "' with exeCost '" + realString(exeCosts1) + "' and Task '" + intString(iTask2) + "' with exeCost '" + realString(exeCosts2) + "'\n");
  oResult := realGt(exeCosts1, exeCosts2);
end compareTasksByExecTime;

protected function getVarsBySCC "author: marcusw,waurich
  Returns all variables of all equations which are part of the component."
  input BackendDAE.StrongComponent iComponent;
  input BackendDAE.IncidenceMatrix iIncidenceMatrix;
  input BackendDAE.Variables iOrderedVars;
  input BackendDAE.Variables iKnownVars; //parameters and constants of SHARED-object
  input BackendDAE.EquationArray iOrderedEquations;
  input Boolean iAnalyzeParameters;
  output list<tuple<Integer,Integer>> oVars; //common variables
  output list<Integer> oParamVars; //parameters (index related to iKnownVars)
algorithm
  (oVars,oParamVars) := match(iComponent, iIncidenceMatrix, iOrderedVars, iKnownVars, iOrderedEquations, iAnalyzeParameters)
    local
      Integer eqnIdx; //For SINGLEEQUATION
      list<Integer> eqns; //For EQUATIONSYSTEM
      list<Integer> resEqns;
      list<tuple<Integer,Integer>> eqnVars;
      list<Integer> paramVars;
      list<tuple<Integer,Integer>> eqnVarsCond;
      list<tuple<Integer,list<Integer>>> otherEqVars;
      String dumpStr;
      BackendDAE.StrongComponent condSys;
    case (BackendDAE.SINGLEEQUATION(eqn=eqnIdx),_,_,_,_,_)
      equation
        (eqnVars, paramVars) = getVarsByEqns({eqnIdx}, iIncidenceMatrix, iOrderedVars, iKnownVars, iOrderedEquations, iAnalyzeParameters);
        _ = List.toString(eqnVars, tupleToString, "", "{", ";", "}", true);
      then
        (eqnVars, paramVars);
    case (BackendDAE.EQUATIONSYSTEM(eqns=eqns),_,_,_,_,_)
      equation
        (eqnVars, paramVars) = getVarsByEqns(eqns, iIncidenceMatrix, iOrderedVars, iKnownVars, iOrderedEquations, iAnalyzeParameters);
      then
        (eqnVars, paramVars);
    case (BackendDAE.SINGLEARRAY(eqn=eqnIdx),_,_,_,_,_)
      equation
        (eqnVars, paramVars) = getVarsByEqns({eqnIdx}, iIncidenceMatrix, iOrderedVars, iKnownVars, iOrderedEquations, iAnalyzeParameters);
        _ = List.toString(eqnVars, tupleToString, "", "{", ";", "}", true);
      then
        (eqnVars, paramVars);
    case (BackendDAE.SINGLEALGORITHM(eqn=eqnIdx),_,_,_,_,_)
      equation
        (eqnVars, paramVars) = getVarsByEqns({eqnIdx}, iIncidenceMatrix, iOrderedVars, iKnownVars, iOrderedEquations, iAnalyzeParameters);
        _ = List.toString(eqnVars, tupleToString, "", "{", ";", "}", true);
      then
        (eqnVars, paramVars);
    case (BackendDAE.SINGLECOMPLEXEQUATION(eqn=eqnIdx),_,_,_,_,_)
      equation
        (eqnVars, paramVars) = getVarsByEqns({eqnIdx}, iIncidenceMatrix, iOrderedVars, iKnownVars, iOrderedEquations, iAnalyzeParameters);
        _ = List.toString(eqnVars, tupleToString, "", "{", ";", "}", true);
      then
        (eqnVars, paramVars);
    case (BackendDAE.SINGLEWHENEQUATION(eqn=eqnIdx),_,_,_,_,_)
      equation
        (eqnVars, paramVars) = getVarsByEqns({eqnIdx}, iIncidenceMatrix, iOrderedVars, iKnownVars, iOrderedEquations, iAnalyzeParameters);
        _ = List.toString(eqnVars, tupleToString, "", "{", ";", "}", true);
      then
        (eqnVars, paramVars);
    case (BackendDAE.SINGLEIFEQUATION(eqn=eqnIdx),_,_,_,_,_)
      equation
        (eqnVars, paramVars) = getVarsByEqns({eqnIdx}, iIncidenceMatrix, iOrderedVars, iKnownVars, iOrderedEquations, iAnalyzeParameters);
        _ = List.toString(eqnVars, tupleToString, "", "{", ";", "}", true);
      then
        (eqnVars, paramVars);
    case (BackendDAE.TORNSYSTEM(residualequations=resEqns,otherEqnVarTpl = otherEqVars),_,_,_,_,_)
      equation
        eqns = List.map(otherEqVars,Util.tuple21);
        (eqnVars, paramVars) = getVarsByEqns(listAppend(resEqns,eqns), iIncidenceMatrix, iOrderedVars, iKnownVars, iOrderedEquations, iAnalyzeParameters);
      then
        (eqnVars, paramVars);
    else
      equation
        print("Error in getVarsBySCC! Unsupported component-type \n");
      then fail();
  end match;
end getVarsBySCC;

public function tupleToString "author: marcusw
  Returns the given tuple as string."
  input tuple<Integer,Integer> inTuple;
  output String result;
algorithm
  result := match(inTuple)
    local
      Integer int1,int2;
    case((int1,int2))
    then ("(" + intString(int1) + "," + intString(int2) + ")");
  end match;
end tupleToString;

protected function tuple3ToString "author: marcusw
  Returns the given tuple as string."
  input tuple<Integer,Integer,Integer> inTuple;
  output String result;
algorithm
  result := match(inTuple)
    local
      Integer int1,int2,int3;
    case((int1,int2,int3))
    then ("(" + intString(int1) + "," + intString(int2) + "," + intString(int3) + ")");
  end match;
end tuple3ToString;

protected function getVarsByEqns "author: marcusw
  Returns all variables of the incidence matrix for the given equation and, if iAnalyzeParameters is set to true, all parameters that are used by the equations."
  input list<Integer> iEqnIdc;
  input BackendDAE.IncidenceMatrix iIncidenceMatrix;
  input BackendDAE.Variables iOrderedVars;
  input BackendDAE.Variables iKnownVars; //parameters and constants of SHARED-object
  input BackendDAE.EquationArray iOrderedEquations;
  input Boolean iAnalyzeParameters;
  output list<tuple<Integer,Integer>> oIncidenceVars;
  output list<Integer> oParamVars;
protected
  list<Integer> incidenceVars = {};
  list<BackendDAE.Var> paramVars = {};
  list<BackendDAE.Equation> eqs = {};
algorithm
  for eqIdx in iEqnIdc loop
    incidenceVars := listAppend(arrayGet(iIncidenceMatrix,eqIdx), incidenceVars);
    eqs := BackendEquation.equationNth1(iOrderedEquations, eqIdx)::eqs;
  end for;
  oIncidenceVars := List.map(incidenceVars, getVarTuple);

  if(iAnalyzeParameters) then
    (paramVars,oParamVars) := BackendEquation.equationsParams(eqs,iKnownVars);
    //print("Found parameters: " + stringDelimitList(List.map(paramVars, BackendDump.varString), ",") + "\n");
  else
    oParamVars := {};
  end if;

end getVarsByEqns;

protected function getVarTuple "author: marcusw
  Converts the given variable to tuple-notation.
  Example:  varIdx = -4 --> (4,0)
            varIdx = 5  --> (5,1)"
  input Integer varIdx;
  output tuple<Integer,Integer> outIdx; //variable index and variable state
algorithm
  outIdx := matchcontinue(varIdx)
    case(_)
      equation
        true = intLe(0,varIdx);
      then ((varIdx, 1));
    else ((-varIdx,0));
   end matchcontinue;
end getVarTuple;

protected function compareIntTuple2 "author: marcusw
  Compares the two given tuples. The result is true if the first and second elements are equal."
  input tuple<Integer,Integer> tuple1;
  input tuple<Integer,Integer> tuple2;
  output Boolean equals;
algorithm
  equals := matchcontinue(tuple1,tuple2)
    local
      Integer int1,int2,int3,int4;
    case((int1,int2),(int3,int4))
      equation
        equality(int1 = int3);
        equality(int2 = int4);
      then true;
    else false;
 end matchcontinue;
end compareIntTuple2;

protected function getVarEqCompMapping "author: marcusw
  Create a mapping between variables / equations and strong-components. The returned array (one element for each variable) contains the
  scc-index which solves the variable."
  input BackendDAE.StrongComponents components;
  input Integer iEqSysIdx;
  input Integer iVarIdxOffset;
  input Integer iEqIdxOffset;
  input array<tuple<Integer,Integer,Integer>> ivarCompMapping;
  input array<tuple<Integer,Integer,Integer>> ieqCompMapping;
  output array<tuple<Integer,Integer,Integer>> ovarCompMapping;
  output array<tuple<Integer,Integer,Integer>> oeqCompMapping;
algorithm
  _ := List.fold4(components, getVarEqCompMapping0, ivarCompMapping, ieqCompMapping, iEqSysIdx, (iVarIdxOffset,iEqIdxOffset), 1);
  ovarCompMapping := ivarCompMapping;
  oeqCompMapping := ieqCompMapping;
end getVarEqCompMapping;

protected function getVarEqCompMapping0 "author: marcusw,waurich
  Updates all array elements which are solved in the given component. The array-elements will be set to iSccIdx."
  input BackendDAE.StrongComponent component;
  input array<tuple<Integer,Integer,Integer>> varCompMapping;
  input array<tuple<Integer,Integer,Integer>> eqCompMapping;
  input Integer iEqSysIdx;
  input tuple<Integer,Integer> iVarEqOffset; //a offset that should be added to the <varIdx,eqIdx>
  input Integer iSccIdx;
  output Integer oSccIdx;
algorithm
  oSccIdx := matchcontinue(component, varCompMapping, eqCompMapping, iEqSysIdx, iVarEqOffset, iSccIdx)
    local
      Integer compVarIdx, iVarOffset, iEqOffset, eq;
      list<Integer> compVarIdc,eqns,residuals,othereqs,othervars;
      array<tuple<Integer,Integer,Integer>> tmpvarCompMapping,tmpeqCompMapping;
      list<tuple<Integer,list<Integer>>> tearEqVarTpl;
      BackendDAE.StrongComponent condSys;
      String helperStr;
    case(BackendDAE.SINGLEEQUATION(var = compVarIdx, eqn = eq),_,_,_,(iVarOffset,iEqOffset),_)
      equation
        //print("HpcOmTaskGraph.getvarCompMapping0 for singleEquation varCompMapping-length:" + intString(arrayLength(varCompMapping)) + " varIdx: " + intString(compVarIdx) + " varOffset: " + intString(iVarOffset) + "\n");
        //print("HpcOmTaskGraph.getvarCompMapping0 for singleEquation eqCompMapping-length:" + intString(arrayLength(eqCompMapping)) + " eqIdx: " + intString(eq) + " eqOffset: " + intString(iEqOffset) + "\n");
        arrayUpdate(varCompMapping,compVarIdx + iVarOffset,(iSccIdx,iEqSysIdx,iVarOffset));
        arrayUpdate(eqCompMapping,eq + iEqOffset,(iSccIdx,iEqSysIdx,iEqOffset));
      then iSccIdx+1;
    case(BackendDAE.EQUATIONSYSTEM(vars = compVarIdc, eqns=eqns),_,_,_,(iVarOffset,iEqOffset),_)
      equation
        _ = List.fold3(compVarIdc,updateMappingTuple,iSccIdx,iEqSysIdx,iVarOffset,varCompMapping);
        _ = List.fold3(eqns,updateMappingTuple,iSccIdx,iEqSysIdx,iEqOffset,eqCompMapping);
      then
        iSccIdx+1;
    case(BackendDAE.SINGLEWHENEQUATION(vars = compVarIdc,eqn = eq),_,_,_,(iVarOffset,iEqOffset),_)
      equation
        _ = List.fold3(compVarIdc,updateMappingTuple,iSccIdx,iEqSysIdx,iVarOffset,varCompMapping);
        arrayUpdate(eqCompMapping,eq + iEqOffset,(iSccIdx,iEqSysIdx,iEqOffset));
      then
        iSccIdx+1;
    case(BackendDAE.SINGLEARRAY(vars = compVarIdc, eqn = eq),_,_,_,(iVarOffset,iEqOffset),_)
      equation
        _ = List.fold3(compVarIdc,updateMappingTuple,iSccIdx,iEqSysIdx,iVarOffset,varCompMapping);
        arrayUpdate(eqCompMapping,eq + iEqOffset,(iSccIdx,iEqSysIdx,iEqOffset));
      then
        iSccIdx+1;
    case(BackendDAE.SINGLEALGORITHM(vars = compVarIdc,eqn = eq),_,_,_,(iVarOffset,iEqOffset),_)
      equation
        _ = List.fold3(compVarIdc,updateMappingTuple,iSccIdx,iEqSysIdx,iVarOffset,varCompMapping);
        arrayUpdate(eqCompMapping,eq + iEqOffset,(iSccIdx,iEqSysIdx,iEqOffset));
        then
          iSccIdx+1;
    case(BackendDAE.SINGLECOMPLEXEQUATION(vars = compVarIdc, eqn = eq),_,_,_,(iVarOffset,iEqOffset),_)
      equation
        _ = List.fold3(compVarIdc,updateMappingTuple,iSccIdx,iEqSysIdx,iVarOffset,varCompMapping);
        arrayUpdate(eqCompMapping,eq + iEqOffset,(iSccIdx,iEqSysIdx,iEqOffset));
        then
          iSccIdx+1;
    case(BackendDAE.TORNSYSTEM(tearingvars = compVarIdc,residualequations = residuals, otherEqnVarTpl = tearEqVarTpl),_,_,_,(iVarOffset,iEqOffset),_)
      equation
      ((othereqs,othervars)) = List.fold(tearEqVarTpl,othersInTearComp,(({},{})));
      compVarIdc = listAppend(othervars,compVarIdc);
      eqns = listAppend(othereqs,residuals);
      _ = List.fold3(compVarIdc,updateMappingTuple,iSccIdx,iEqSysIdx,iVarOffset,varCompMapping);
      _ = List.fold3(eqns,updateMappingTuple,iSccIdx,iEqSysIdx,iEqOffset,eqCompMapping);
      then
        iSccIdx+1;
    case(BackendDAE.SINGLEIFEQUATION(vars = compVarIdc, eqn = eq),_,_,_,(iVarOffset,iEqOffset),_)
      equation
        _ = List.fold3(compVarIdc,updateMappingTuple,iSccIdx,iEqSysIdx,iVarOffset,varCompMapping);
        arrayUpdate(eqCompMapping,eq + iEqOffset,(iSccIdx,iEqSysIdx,iEqOffset));
        then
          iSccIdx+1;
    else
      equation
        helperStr = BackendDump.strongComponentString(component);
        print("getVarEqCompMapping0 - Unsupported component-type:\n" + helperStr + "\n");
      then fail();
  end matchcontinue;
end getVarEqCompMapping0;

public function getSccNodeMapping "author: marcusw
  Create a mapping between the strong components and the graph nodes"
  input Integer iNumberOfSccs;
  input TaskGraphMeta iTaskGraphMeta;
  output array<Integer> oMapping; //each scc (arrayIdx) is mapped to exactly one node (value)
protected
  array<Integer> tmpMappingArray;
  array<list<Integer>> inComps;
  array<Integer> nodeMark;
algorithm
  tmpMappingArray := arrayCreate(iNumberOfSccs,-1);
  TASKGRAPHMETA(inComps=inComps,nodeMark=nodeMark) := iTaskGraphMeta;
  ((oMapping,_)) := Array.fold1(inComps, getSccNodeMapping0, nodeMark, (tmpMappingArray,1));
end getSccNodeMapping;

protected function getSccNodeMapping0 "author: marcusw
  Set all array entries of the given scc-list to the node-idx"
  input list<Integer> iCompsOfNode;
  input array<Integer> iNodeMarks;
  input tuple<array<Integer>, Integer> iArrayNodeIdx;
  output tuple<array<Integer>, Integer> oArrayNodeIdx;
protected
  array<Integer> tmpMappingArray;
  Integer nodeIdx;
algorithm
  ((tmpMappingArray,nodeIdx)) := List.fold1(iCompsOfNode, getSccNodeMapping1, iNodeMarks, iArrayNodeIdx);
  oArrayNodeIdx := (tmpMappingArray,nodeIdx+1);
end getSccNodeMapping0;

protected function getSccNodeMapping1 "author: marcusw
  Set all array entries of the given scc-list to the node-idx"
  input Integer iCompIdx;
  input array<Integer> iNodeMark;
  input tuple<array<Integer>, Integer> iArrayNodeIdx;
  output tuple<array<Integer>, Integer> oArrayNodeIdx;
protected
  Integer iNodeIdx;
  Integer offset;
  Integer nodeMark;
  array<Integer> iMappingArray;
algorithm
  oArrayNodeIdx := matchcontinue(iCompIdx,iNodeMark,iArrayNodeIdx)
    case(_,_,(iMappingArray,iNodeIdx))
      equation
        nodeMark = arrayGet(iNodeMark,iCompIdx);
        true = intNe(-1,nodeMark);
        iMappingArray = arrayUpdate(iMappingArray, iCompIdx, iNodeIdx);
      then ((iMappingArray,iNodeIdx));
    case(_,_,(iMappingArray,iNodeIdx))
      then ((iMappingArray,iNodeIdx));
  end matchcontinue;
end getSccNodeMapping1;

protected function othersInTearComp " gets the remaining algebraic vars and equations from the torn block.
Remark: there can be more than 1 var per equation.
author:Waurich TUD 2013-06"
  input tuple<Integer,list<Integer>> otherEqnVarTpl;
  input tuple<list<Integer>,list<Integer>> othersIn;
  output tuple<list<Integer>,list<Integer>> othersOut;
algorithm
  othersOut := matchcontinue(otherEqnVarTpl,othersIn)
    local
      Integer eq;
      Integer var;
      list<Integer> eqLst;
      list<Integer> varTplLst;
      list<Integer> varLst;
    case(_,_)
      equation
      (eq,varTplLst)=otherEqnVarTpl;
      _ = listGet(varTplLst,1);
      (eqLst,varLst) = othersIn;
      varLst = listAppend(varTplLst,varLst);
      eqLst = eq::eqLst;
      then
        ((eqLst,varLst));
    else
      equation
      print("check number of vars in relation to number of eqs in otherEqnVarTpl in the torn system\n");
      then
        fail();
  end matchcontinue;
end othersInTearComp;

protected function updateMapping
  input Integer varIdx;
  input Integer sccIdx;
  input array<Integer> iMapping;
  output array<Integer> oMapping;
algorithm
  oMapping := arrayUpdate(iMapping,varIdx,sccIdx);
end updateMapping;

protected function updateMappingTuple
  input Integer varIdx;
  input Integer sccIdx;
  input Integer iEqSysIdx;
  input Integer iVarOffset; //a offset that should be added to the varIdx
  input array<tuple<Integer,Integer,Integer>> iMapping;
  output array<tuple<Integer,Integer,Integer>> oMapping;
algorithm
  oMapping := arrayUpdate(iMapping,varIdx+iVarOffset,(sccIdx,iEqSysIdx,iVarOffset));
end updateMappingTuple;


//--------------------------------------------------------
//  Functions to get the ODEsystem graph and adjacencyList
//--------------------------------------------------------

public function getOdeSystem "gets the graph and the adjacencyLst only for the ODEsystem. the der(states) and nodes that evaluate zerocrossings are the only branches of the task graph
attention: This function will overwrite the values of graphIn and graphDataIn with new values. If you want to hold the values of graphIn and graphDataIn, you have to duplicate them first!
author: Waurich TUD 2013-06"
  input TaskGraph graphIn;
  input TaskGraphMeta graphDataIn;
  input BackendDAE.BackendDAE systIn;
  output TaskGraph graphOdeOut;
  output TaskGraphMeta graphDataOdeOut;
protected
  list<Integer> stateNodes, whenNodes, cutNodes, cutNodeChildren;
  array<tuple<Integer, Integer, Integer>> varCompMapping, eqCompMapping;
  array<list<Integer>> inComps;
  BackendDAE.EqSystems systs;
  TaskGraph graphTmp;
  TaskGraphMeta graphDataTmp;
algorithm
  TASKGRAPHMETA(varCompMapping=varCompMapping, eqCompMapping=eqCompMapping, inComps=inComps) := graphDataIn;
  BackendDAE.DAE(systs,_) := systIn;
  ((stateNodes,_)) := List.fold2(systs,getAllStateNodes,varCompMapping,inComps,({},0));
  whenNodes := getEventNodes(systIn,eqCompMapping);
  graphTmp := arrayCopy(graphIn);
  (graphOdeOut,cutNodes) := cutTaskGraph(graphTmp,stateNodes,whenNodes);
  cutNodeChildren := List.flatten(List.map1(listAppend(cutNodes,whenNodes),Array.getIndexFirst,graphIn)); // for computing new root-nodes when cutting out when-equations
  (_,cutNodeChildren,_) := List.intersection1OnTrue(cutNodeChildren,cutNodes,intEq);
  graphDataOdeOut := cutSystemData(graphDataIn,listAppend(cutNodes,{}),cutNodeChildren);
end getOdeSystem;

protected function getAllStateNodes "folding function for getOdeSystem to traverse the equationsystems in the BackendDAE.
author: Waurich TUD 2013-07"
  input BackendDAE.EqSystem systIn;
  input array<tuple<Integer, Integer, Integer>> varCompMapping;
  input array<list<Integer>> inComps;
  input tuple<list<Integer>,Integer> stateInfoIn;
  output tuple<list<Integer>,Integer> stateInfoOut;
algorithm
  stateInfoOut := matchcontinue(systIn,varCompMapping,inComps,stateInfoIn)
    local
      list<Integer> stateNodes, stateNodesIn, stateVars;
      Integer varOffset, varOffsetNew;
      BackendDAE.Variables orderedVars;
      list<BackendDAE.Var> varLst;
  case(_,_,_,((stateNodesIn,varOffset)))
    equation
      BackendDAE.EQSYSTEM(orderedVars=orderedVars) = systIn;
      varLst = BackendVariable.varList(orderedVars);
      stateVars = getStates(varLst,{},1);
      //print("stateVars: " + stringDelimitList(List.map(stateVars,intString),",") + " varOffset: " + intString(varOffset) + "\n");
      //print("varCompMapping: " + stringDelimitList(arrayList(Array.map(varCompMapping,tuple3ToString)),",") + "\n");
      true = List.isNotEmpty(stateVars);
      stateVars = List.map1(stateVars,intAdd,varOffset);
      stateNodes = getArrayTuple31(stateVars,varCompMapping);
      //print("stateNodes: " + stringDelimitList(List.map(stateNodes,intString),",") + "\n");
      stateNodes = List.map3(stateNodes,getCompInComps,1,inComps,arrayCreate(arrayLength(inComps),0));
      stateNodes = listAppend(stateNodesIn,stateNodes);
      varOffsetNew = listLength(varLst)+varOffset;
    then
      ((stateNodes,varOffsetNew));
  case(_,_,_,(stateNodesIn,varOffset))
    equation
      BackendDAE.EQSYSTEM(orderedVars=orderedVars) = systIn;
      varLst = BackendVariable.varList(orderedVars);
      stateVars = getStates(varLst,{},1);
      true = List.isEmpty(stateVars);
      varOffsetNew = listLength(varLst)+varOffset;
      then
        ((stateNodesIn,varOffsetNew));
  case(_,_,_,(_,_))
    equation
      BackendDAE.EQSYSTEM(orderedVars=orderedVars) = systIn;
      varLst = BackendVariable.varList(orderedVars);
      stateVars = getStates(varLst,{},1);
      print("getAllStateNodes failed! StateVars-Count: " + intString(listLength(stateVars)) + "\n");
     then fail();
  end matchcontinue;
end getAllStateNodes;

protected function getStates "gets the stateVars from the list of vars.
author:Waurich TUD 2013-06"
  input list<BackendDAE.Var> inVarLst;
  input list<Integer> stateVarsIn;
  input Integer Idx;
  output list<Integer> stateVarsOut;
algorithm
  stateVarsOut := matchcontinue(inVarLst,stateVarsIn,Idx)
    local
      BackendDAE.Var head;
      list<BackendDAE.Var> rest;
      list<Integer> stateVars;
    case((head::rest),_,_)
      equation
        false = BackendVariable.isStateVar(head);
        stateVars = getStates(rest,stateVarsIn,Idx+1);
      then stateVars;
    case((head::rest),_,_)
      equation
        true = BackendVariable.isStateVar(head);
        stateVars = getStates(rest,Idx::stateVarsIn,Idx+1);
      then stateVars;
    case({},_,_)
      then stateVarsIn;
   end matchcontinue;
 end getStates;

protected function cutTaskGraph "cuts every branch of the taskGraph that leads not to exceptNode.
author:Waurich TUD 2013-06"
  input TaskGraph graphIn;
  input list<Integer> exceptNodes;// dont cut them and their predecessors
  input list<Integer> whenNodes;// these can be removed even if they are predecessors of the exceptNodes
  output TaskGraph graphOut;
  output list<Integer> cutNodesOut;
algorithm
  (graphOut,cutNodesOut) := matchcontinue(graphIn,exceptNodes,whenNodes)
    local
      Integer sizeDAE,sizeODE;
      TaskGraph graphT, graphODE;
      list<Integer> cutNodes,odeNodes;
      array<Integer> odeMap;
      list<list<Integer>> graphTmpLst;
    case(_,{-1},_)
      equation
      then (graphIn,{});
    case(_,_,_)
      equation
        // remove the algebraic branches
        sizeDAE = arrayLength(graphIn);
        graphT = BackendDAEUtil.transposeMatrix(graphIn,sizeDAE);
        odeNodes = listAppend(exceptNodes,getAllSuccessors(exceptNodes,graphT));//the ODE-System
        (_,odeNodes,_) = List.intersection1OnTrue(odeNodes,whenNodes,intEq);
        (odeNodes,_,_) = List.intersection1OnTrue(List.intRange(sizeDAE),odeNodes,intEq);

        odeNodes = List.sort(odeNodes,intGt);
        sizeODE = listLength(odeNodes);
        odeMap = arrayCreate(sizeDAE,-1);
        List.threadMap1_0(odeNodes,List.intRange(sizeODE),Array.updateIndexFirst,odeMap);
        graphODE = arrayCreate(sizeODE,{});
        (graphODE,cutNodes) = cutTaskGraph2(List.intRange(sizeDAE),graphODE,{},graphIn,odeMap);
      then (graphODE,cutNodes);
    else
      equation
        print("cutTaskGraph failed\n");
      then fail();
  end matchcontinue;
end cutTaskGraph;

protected function cutTaskGraph2"uses a mapping between daeIdx and odeIdx (or for DAE-eqs -1) and builds up a new ode graph.
the ode nodes are mapped to new indeces and the dae eqs are skipped.
author:Waurich TUD 2013-04"
  input list<Integer> daeNodes;
  input TaskGraph graphODE;
  input list<Integer> cutNodesIn;
  input TaskGraph graphDAE;
  input array<Integer> odeMap;
  output TaskGraph graphOut;
  output list<Integer> cutNodesOut;
algorithm
  (graphOut,cutNodesOut) := matchcontinue(daeNodes,graphODE,cutNodesIn,graphDAE,odeMap)
    local
      Integer daeIdx,odeIdx;
      list<Integer> rest,row,cutNodes;
      TaskGraph graphTmp;
    case(daeIdx::rest,_,_,_,_)
      equation
        odeIdx = arrayGet(odeMap,daeIdx);
        true = intGt(odeIdx,0);  // this node is still in the ODE system
        row = arrayGet(graphDAE,daeIdx);
        row = List.map1(row,Array.getIndexFirst,odeMap);
        row = List.filter1OnTrue(row,intGt,0);
        arrayUpdate(graphODE,odeIdx,row);
        (_,cutNodes) = cutTaskGraph2(rest,graphODE,cutNodesIn,graphDAE,odeMap);
      then (graphODE,cutNodes);
    case(daeIdx::rest,_,_,_,_)
      equation
        odeIdx = arrayGet(odeMap,daeIdx);
        true = intEq(odeIdx,-1);  // this node ist not in the ODE system
        (_,cutNodes) = cutTaskGraph2(rest,graphODE,daeIdx::cutNodesIn,graphDAE,odeMap);
      then (graphODE,cutNodes);
    case({},_,_,_,_)
      then (graphODE,cutNodesIn);
  end matchcontinue;
end cutTaskGraph2;

protected function cutSystemData "updates the taskGraphMetaData regarding the removed nodes.
author:Waurich TUD 2013-07"
  input TaskGraphMeta graphDataIn;
  input list<Integer> cutNodes;
  input list<Integer> cutNodeChildren;
  output TaskGraphMeta graphDataOut;
protected
  array<list<Integer>> inComps;
  array<tuple<Integer, Integer, Integer>> varCompMapping;
  array<tuple<Integer, Integer, Integer>> eqCompMapping;
  array<String> compNames;
  array<String> compDescs;
  array<tuple<Integer,Real>> exeCosts;
  array<Communications> commCosts;
  array<Integer> nodeMark;
  list<Integer> rangeLst;
  array<list<Integer>> compParamMapping;
  array<ComponentInfo> compInformations;
algorithm
  TASKGRAPHMETA(inComps=inComps, varCompMapping=varCompMapping, eqCompMapping=eqCompMapping, compParamMapping=compParamMapping, compNames=compNames, compDescs=compDescs, exeCosts=exeCosts, commCosts=commCosts, nodeMark=nodeMark, compInformations=compInformations) := graphDataIn;
  inComps := listArray(List.deletePositions(arrayList(inComps),List.map1(cutNodes,intSub,1)));
  rangeLst := List.intRange(arrayLength(nodeMark));
  nodeMark := List.fold1(rangeLst, markRemovedNodes,cutNodes,nodeMark);
  graphDataOut :=TASKGRAPHMETA(inComps,varCompMapping,eqCompMapping,compParamMapping,compNames,compDescs,exeCosts,commCosts,nodeMark,compInformations);
end cutSystemData;

protected function markRemovedNodes " folding function to set the entries in nodeMark to -1 for a removed component
author:Waurich TUD 2013-07"
  input Integer nodeMarkIdx;
  input list<Integer> removedNodes;
  input array<Integer> nodeMarkIn;
  output array<Integer> nodeMarkOut;
algorithm
  nodeMarkOut := matchcontinue(nodeMarkIdx,removedNodes,nodeMarkIn)
    local
      array<Integer> nodeMarkTmp;
  case(_,_,_)
    equation
      true = intEq(-2, arrayGet(nodeMarkIn,nodeMarkIdx));
  then nodeMarkIn;
  case(_,_,_)
    equation
      false = List.isMemberOnTrue(nodeMarkIdx,removedNodes,intEq);
    then
      nodeMarkIn;
  case(_,_,_)
    equation
      true = List.isMemberOnTrue(nodeMarkIdx,removedNodes,intEq);
      nodeMarkTmp = Array.replaceAtWithFill(nodeMarkIdx,-1,999,nodeMarkIn);
    then
      nodeMarkTmp;
  end matchcontinue;
end markRemovedNodes;

public function getCompInComps "finds the node in the current task graph which contains that component(index from the original task graph). nodeMark is needed to check for deleted components
author: Waurich TUD 2013-07"
  input Integer compIn;
  input Integer compIdx;  // start idx for iteration
  input array<list<Integer>> inComps;
  input array<Integer> nodeMark;
  output Integer compOut;
algorithm
  compOut := matchcontinue(compIn,compIdx,inComps, nodeMark)
    local
      list<Integer> mergedComp;
      Integer compTmp;
      Integer nodeMarkEntry;
    case(_,_,_,_)
      equation
        true = arrayLength(inComps) >= compIdx;
        mergedComp = arrayGet(inComps,compIdx);
        //print("get comp for compIn "+intString(compIn)+" in the merged Comp "+ stringDelimitList(List.map(mergedComp,intString),",")+"\n");
        false = List.isMemberOnTrue(compIn,mergedComp,intEq);
        compTmp = getCompInComps(compIn,compIdx+1,inComps,nodeMark);
      then
        compTmp;
    case(_,_,_,_)
      equation
        true = arrayLength(inComps) >= compIdx;
        mergedComp = arrayGet(inComps,compIdx);
        //print("get comp for compIn "+intString(compIn)+" in the merged Comp "+ stringDelimitList(List.map(mergedComp,intString),",")+"\n");
        true = List.isMemberOnTrue(compIn,mergedComp,intEq);
      then
        compIdx;
    case(_,_,_,_)
      equation
        nodeMarkEntry = arrayGet(nodeMark,compIn);
        true = intLt(nodeMarkEntry,0);
      then
        -1;
    else
      equation
        print("getCompInComps failed! CompIn idx: " + intString(compIn) + " | Component array-size: " + intString(arrayLength(inComps)) + "\n");
      then
        fail();
  end matchcontinue;
end getCompInComps;

protected function getAllSuccessors"gets all successors including all childNodes of the childNodes...
author:Waurich TUD 2014-09"
  input list<Integer> nodes;
  input TaskGraph graph;
  output list<Integer> successors;
algorithm
  successors := matchcontinue(nodes,graph)
    local
      array<Boolean> alreadyVisited;
      list<Boolean> check;
      list<Integer> successors1, successors2;
    case(_,_)
      equation
        alreadyVisited = arrayCreate(arrayLength(graph),false);
        List.map2_0(nodes,Array.updateIndexFirst,true,alreadyVisited); // dont use the except nodes
        successors1 = List.flatten(List.map1(nodes,Array.getIndexFirst,graph));
        check = List.map1(successors1,Array.getIndexFirst,alreadyVisited);  //check if it was already visited?
        (_,successors1) = List.filterOnTrueSync(check,boolNot,successors1);
        successors1 = List.unique(successors1);
      then getAllSuccessors2(successors1,graph,alreadyVisited,successors1);
    else
      equation
        print("getAllSuccessors failed!\n");
      then fail();
  end matchcontinue;
end getAllSuccessors;

protected function getAllSuccessors2"gets all successors for the given nodes and repeats it for the successors until the end of the graph.
author: Waurich TUD 2014-09"
  input list<Integer> nodes;
  input TaskGraph graph;
  input array<Boolean> alreadyVisited;
  input list<Integer> successorsIn;
  output list<Integer> successorsOut;
algorithm
  successorsOut := match(nodes,graph,alreadyVisited,successorsIn)
    local
      list<Boolean> check;
      list<Integer> successors1;
    case({},_,_,_)
      then List.unique(successorsIn);
    case(_,_,_,_)
      equation
        successors1 = List.flatten(List.map1(nodes,Array.getIndexFirst,graph));
        check = List.map1(successors1,Array.getIndexFirst,alreadyVisited);  //check if it was already visited?
        (_,successors1) = List.filterOnTrueSync(check,boolNot,successors1);
        successors1 = List.unique(successors1);
        //print("successors1: "+intLstString(successors1)+"\n");
        List.map2_0(successors1,Array.updateIndexFirst,true,alreadyVisited);
    then getAllSuccessors2(successors1,graph,alreadyVisited,listAppend(successors1,successorsIn));
  end match;
end getAllSuccessors2;

public function getChildNodes "gets the successor nodes for a list of parent nodes.
author: waurich TUD 2013-06"
  input array<list<Integer>> adjacencyLstIn;
  input list<Integer> parents;
  input list<Integer> childLstTmp;
  input Integer Idx;
  output list<Integer> childLsts;
algorithm
  childLsts := matchcontinue(adjacencyLstIn,parents,childLstTmp,Idx)
    local
      Integer parent;
      list<Integer> row;
      list<Integer> childLst;
    case(_,_,_,_)
      equation
        true = listLength(parents) >= Idx;
        parent = listGet(parents,Idx);
        row = arrayGet(adjacencyLstIn,parent);
        childLst = listAppend(childLstTmp,row);
        childLst = getChildNodes(adjacencyLstIn,parents,childLst,Idx+1);
      then
        childLst;
    else childLstTmp;
  end matchcontinue;
end getChildNodes;

public function updateContinuousEntriesInList" updates the entries in a list
the entries in the list belong to a continuous series.
the deleteEntries have been previously removed from the array and the indices are adapted so that the new array consists again of continuous series of numbers.therefore the indices have to be smallen
e.g. updateContinuousEntriesInList({4,2,1,7,9},{3,6}) = {3,2,1,5,7};
!! only for positive entries.
author: Waurich TUD 2013-07"
  input list<Integer> lstIn;
  input list<Integer> deleteEntriesIn;
  output list<Integer> lstOut;
algorithm
  lstOut := match(lstIn,deleteEntriesIn)
    local
      Integer start;
      list<Integer> deleteEntries, rest, lstTmp;
      array<Integer> deleteArr;
   case({},_)
     then {};
   case(_,{})
     then lstIn;
   case(start::rest,_)
     equation
        deleteArr = arrayCreate(List.fold(listAppend(rest,deleteEntriesIn),intMax,start),0);
        List.map2_0(deleteEntriesIn,Array.updateIndexFirst,1,deleteArr);
        (deleteEntries,_) = List.mapFold(arrayList(deleteArr),setDeleteArr,0);
        deleteArr = listArray(deleteEntries);
        lstTmp = List.map1(lstIn,removeContinuousEntries1,deleteArr);
     then lstTmp;
    end match;
end updateContinuousEntriesInList;

protected function setDeleteArr
  input Integer entryIn;
  input Integer offsetIn;
  output Integer entryOut;
  output Integer offsetOut;
algorithm
  (entryOut,offsetOut) := match(entryIn,offsetIn)
  case(0,_)
      then (offsetIn,offsetIn);
  case(1,_)
      then (offsetIn+1,offsetIn+1);
  end match;
end setDeleteArr;

protected function removeContinuousEntries1" map function for removeContinuousEntries to update the indices.
author:Waurich TUD 2013-07."
  input Integer entryIn;
  input array<Integer> deleteEntriesIn;
  output Integer entryOut;
protected
  Integer eqSysIdx, entryOffset;
algorithm
  entryOut := matchcontinue(entryIn,deleteEntriesIn)
  local
    Integer offset;
  case(_,_)
    equation
      offset = arrayGet(deleteEntriesIn,entryIn);
    then entryIn-offset;
  else
    equation
      print("removeContinuousEntries1 failed!\n");
    then entryIn;
  end matchcontinue;
end removeContinuousEntries1;

protected function deleteRowInAdjLst "deletes rows indexed by the rowDel from the adjacencyLst.
author:waurich TUD 2013 - 06"
  input array<list<Integer>> adjacencyLstIn;
  input list<Integer> rowsDel;
  output array<list<Integer>> adjacencyLstOut;
  output list<Integer> odeMapping;
protected
  array<list<Integer>> adjLst;
  list<Integer> copiedRows;
  list<Integer> rowsDel1;
  Integer size;
algorithm
  size := arrayLength(adjacencyLstIn)-listLength(rowsDel);
  adjLst := arrayCreate(size,{});
  copiedRows := List.intRange(arrayLength(adjacencyLstIn));
  rowsDel1 := List.map1(rowsDel,intSub,1);
  copiedRows := List.deletePositions(copiedRows,rowsDel1);
  adjacencyLstOut := arrayCopyRows(adjacencyLstIn,adjLst,copiedRows,1);
  odeMapping := copiedRows;
end deleteRowInAdjLst;

protected function arrayCopyRows "copies entries given by copiedRows from inArray to newArray"
  input array<list<Integer>> inArray;
  input array<list<Integer>> newArray;
  input list<Integer> copiedRows;
  input Integer Idx;
  output array<list<Integer>> outArray;
algorithm
  outArray := matchcontinue(inArray,newArray,copiedRows,Idx)
    local
      Integer head;
      Integer copyRow;
      list<Integer> rest;
      list<Integer> row;
      array<list<Integer>> arrayTmp;
    case(_,_,_,_)
      equation
        true = listLength(copiedRows) >= Idx;
        copyRow = listGet(copiedRows,Idx);
        row = arrayGet(inArray,copyRow);
        arrayTmp = Array.replaceAtWithFill(Idx, row, {111,222}, newArray);
        arrayTmp = arrayCopyRows(inArray,arrayTmp,copiedRows,Idx+1);
      then
        arrayTmp;
    else
      equation
      then
        newArray;
  end matchcontinue;
end arrayCopyRows;

public function getRootNodes "function getRootNodes
  author: marcusw,waurich
  Get all root nodes of the graph."
  input TaskGraph iTaskGraph; //the original graph
  output list<Integer> rootsOut;
protected
  Integer size;
  TaskGraph taskGraphT;
algorithm
  size := arrayLength(iTaskGraph);
  taskGraphT := BackendDAEUtil.transposeMatrix(iTaskGraph,size);
  rootsOut := getLeafNodes(taskGraphT);  // gets the leaf nodes of the transposed graph
end getRootNodes;

public function getLeafNodes "author: marcusw
  Get all leaf-nodes of the given graph."
  input TaskGraph iTaskGraph;
  output list<Integer> oLeafNodes;
protected
  list<Integer> tmpLeafNodes, nodeSuccessors;
  Integer nodeIdx;
algorithm
  tmpLeafNodes := {};
  for nodeIdx in 1:arrayLength(iTaskGraph) loop
    nodeSuccessors := arrayGet(iTaskGraph, nodeIdx);
    if(listEmpty(nodeSuccessors)) then
      tmpLeafNodes := nodeIdx::tmpLeafNodes;
    end if;
  end for;
  oLeafNodes := tmpLeafNodes;
end getLeafNodes;

public function getLevelNodes "author: marcusw
  Get all nodes that belong to the levels."
  input TaskGraph iTaskGraph;
  output list<list<Integer>> oLevelNodes; //list of nodes for each level
protected
  array<Integer> refCounter;
  list<Integer> roots;
algorithm
  refCounter := createRefCounter(iTaskGraph);
  roots := getNodesWithRefCountZero(refCounter);
  oLevelNodes := getLevelNodes0(iTaskGraph, refCounter, roots, {});
end getLevelNodes;

protected function getLevelNodes0 "author: marcusw
  Adds all nodes in list iNodesWithRefZero as a new level to the result list. After that, the reference counter
  of all child nodes is decremented and the function is invoked again with the new referenceCount=0 nodes."
  input TaskGraph iTaskGraph;
  input array<Integer> iRefCounter;
  input list<Integer> iNodesWithRefZero;
  input list<list<Integer>> iLevelNodes; //list of nodes for each level
  output list<list<Integer>> oLevelNodes;
protected
  list<list<Integer>> tmpLevelNodes;
  list<Integer> zeroRefNodes;
algorithm
  oLevelNodes := match(iTaskGraph,iRefCounter, iNodesWithRefZero, iLevelNodes)
    case(_,_,{},_)
      equation //no nodes with refCount = 0 -> all nodes handled
        tmpLevelNodes = listReverse(iLevelNodes);
      then tmpLevelNodes;
    case(_,_,zeroRefNodes,_)
      equation
        //append all nodes with refCount = zero as new level
        tmpLevelNodes = zeroRefNodes :: iLevelNodes;
        zeroRefNodes = List.fold2(zeroRefNodes, getLevelNodes1, iTaskGraph, iRefCounter, {});
        tmpLevelNodes = getLevelNodes0(iTaskGraph, iRefCounter, zeroRefNodes, tmpLevelNodes);
      then tmpLevelNodes;
  end match;
end getLevelNodes0;

protected function getLevelNodes1 "author: marcusw
  Decrements the reference counter of all child nodes of the node (iNodeIdx).
  If the child node has a reference counter of zero after decrementation, the child is added to the result list."
  input Integer iNodeIdx;
  input TaskGraph iTaskGraph;
  input array<Integer> iRefCounter; //updated through the arrayUpdate-command
  input list<Integer> iNodesWithRefZero;
  output list<Integer> oNodesWithRefZero;
protected
  list<Integer> childNodes, tmpNodesWithRefZero;
algorithm
  childNodes := arrayGet(iTaskGraph, iNodeIdx);
  tmpNodesWithRefZero := List.fold1(childNodes, getLevelNodes2, iRefCounter, {});
  oNodesWithRefZero := listAppend(tmpNodesWithRefZero, iNodesWithRefZero);
end getLevelNodes1;

protected function getLevelNodes2 "author: marcusw
  Decrement the reference counter of node (iNodeIdx) and add it to the result-list if the reference-counter is zero."
  input Integer iNodeIdx;
  input array<Integer> iRefCounter; //updated through the arrayUpdate-command
  input list<Integer> iNodesWithRefZero;
  output list<Integer> oNodesWithRefZero;
protected
  list<Integer> tmpNodesWithRefZero;
  Integer refCounter;
algorithm
  oNodesWithRefZero := matchcontinue(iNodeIdx, iRefCounter, iNodesWithRefZero)
    case(_,_,tmpNodesWithRefZero)
      equation
        refCounter = arrayGet(iRefCounter, iNodeIdx) - 1;
        arrayUpdate(iRefCounter, iNodeIdx, refCounter);
        true = intEq(refCounter, 0);
        tmpNodesWithRefZero = iNodeIdx::tmpNodesWithRefZero;
      then tmpNodesWithRefZero;
    else iNodesWithRefZero;
  end matchcontinue;
end getLevelNodes2;

protected function createRefCounter "author: marcusw
  Setup a reference counter (number of incoming edges) for each node (array-index)."
  input TaskGraph iTaskGraph;
  output array<Integer> oRefCounter;
protected
  array<Integer> tmpRefCounter;
algorithm
  tmpRefCounter := arrayCreate(arrayLength(iTaskGraph), 0);
  tmpRefCounter := Array.fold(iTaskGraph, createRefCounter0, tmpRefCounter);
  oRefCounter := tmpRefCounter;
end createRefCounter;

protected function createRefCounter0 "author: marcusw
  Increment the ref-counter of all child tasks of the given node."
  input list<Integer> iChildNodes;
  input array<Integer> iRefCounter;
  output array<Integer> oRefCounter;
protected
  array<Integer> tmpRefCounter;
  Integer counter, head;
  list<Integer> tail;
algorithm
  oRefCounter := match(iChildNodes, iRefCounter)
    case({},_) then iRefCounter;
    case(head::tail,_)
      equation
        counter = arrayGet(iRefCounter,head) + 1;
        tmpRefCounter = arrayUpdate(iRefCounter,head,counter);
        tmpRefCounter = createRefCounter0(tail,tmpRefCounter);
      then tmpRefCounter;
  end match;
end createRefCounter0;

protected function getNodesWithRefCountZero "author: marcusw
  Return the nodes of the ref-counter-array that have a reference-count of zero."
  input array<Integer> iRefCounter;
  output list<Integer> oZeroIdc; //list of all indices with reference counter == zero
algorithm
  ((oZeroIdc,_)) := Array.fold(iRefCounter, getNodesWithRefCountZero0, ({},1));
end getNodesWithRefCountZero;

protected function getNodesWithRefCountZero0 "author: marcusw
  Add the currentNodeIdx to the result-list if the iRefCount-value is zero."
  input Integer iRefCount;
  input tuple<list<Integer>,Integer> iZeroIdc; //<resultList, currentNodeIdx>
  output tuple<list<Integer>,Integer> oZeroIdc;
protected
  list<Integer> resultList;
  Integer currentNodeIdx;
algorithm
  oZeroIdc := match(iRefCount, iZeroIdc)
    case(0,(resultList,currentNodeIdx))
      equation
        resultList = currentNodeIdx :: resultList;
      then ((resultList, currentNodeIdx+1));
    case(_,(resultList,currentNodeIdx))
      then ((resultList, currentNodeIdx+1));
  end match;
end getNodesWithRefCountZero0;


//----------------------------------
//  Functions to get the event-graph
//----------------------------------

public function getEventSystem "gets the graph and the adjacencyLst only for the EventSystem. This means that all branches which leads to a node solving
a whencondition or another boolean condition will remain.
author: marcusw"
  input TaskGraph iTaskGraph;
  input TaskGraphMeta iTaskGraphMeta;
  input BackendDAE.BackendDAE iSyst;
  input list<BackendDAE.ZeroCrossing> iZeroCrossings;
  input array<Integer> iSimCodeEqCompMapping;
  output TaskGraph oTaskGraph;
  output TaskGraphMeta oTaskGraphMeta;
protected
  array<tuple<Integer, Integer, Integer>> varCompMapping, eqCompMapping;
  array<list<Integer>> inComps;
  list<Integer> discreteNodes, cutNodes, cutNodeChildren, zeroCrossingNodes;
  list<Integer> sccsContainingTime;
  BackendDAE.EqSystems systs;
  BackendDAE.Shared shared;
  TaskGraph graphTmp;
  TaskGraphMeta graphDataTmp;
algorithm
  TASKGRAPHMETA(varCompMapping=varCompMapping, eqCompMapping=eqCompMapping, inComps=inComps) := iTaskGraphMeta;
  BackendDAE.DAE(systs,shared) := iSyst;
  discreteNodes := getDiscreteNodes(iSyst,eqCompMapping);
  zeroCrossingNodes := List.flatten(List.map1(iZeroCrossings, getComponentsOfZeroCrossing, iSimCodeEqCompMapping));
  //((_,sccsContainingTime)) := List.fold1(systs, getComponentsIncludingTime, eqCompMapping, (0,{}));
  sccsContainingTime := {};
  //print("Nodes containing time as variable: " + stringDelimitList(List.map(sccsContainingTime, intString), ",") + " (len: " + intString(listLength(sccsContainingTime)) + ")\n");
  discreteNodes := listAppend(discreteNodes, sccsContainingTime);
  discreteNodes := listAppend(discreteNodes, zeroCrossingNodes);
  discreteNodes := List.unique(discreteNodes);
  //print("Discrete nodes: " + stringDelimitList(List.map(discreteNodes, intString), ",") + " (len: " + intString(listLength(discreteNodes)) + ")\n");
  graphTmp := iTaskGraph; //arrayCopy(graphIn);
  (graphTmp,cutNodes) := cutTaskGraph(graphTmp,discreteNodes,{});
  cutNodeChildren := List.flatten(List.map1(cutNodes,Array.getIndexFirst,iTaskGraph)); // for computing new root-nodes when cutting out nodes
  (_,cutNodeChildren,_) := List.intersection1OnTrue(cutNodeChildren,cutNodes,intEq);
  oTaskGraphMeta := cutSystemData(iTaskGraphMeta,cutNodes,cutNodeChildren);
  oTaskGraph := graphTmp;
end getEventSystem;

protected function getComponentsOfZeroCrossing "get the scc-idc that use the given zero crossing.
author: marcusw"
  input BackendDAE.ZeroCrossing iZeroCrossing;
  input array<Integer> iSimCodeEqCompMapping;
  output list<Integer> oCompIdc;
protected
  list<Integer> occurEquLst, tmpCompIdc;
algorithm
  oCompIdc := matchcontinue(iZeroCrossing, iSimCodeEqCompMapping)
    case(BackendDAE.ZERO_CROSSING(occurEquLst=occurEquLst), _)
      equation
        occurEquLst = List.filter1OnTrue(occurEquLst, intGt, 0);
        //print("getComponentsOfZeroCrossing: simEqs: " + stringDelimitList(List.map(occurEquLst, intString), ",") + "\n");
        tmpCompIdc = List.map1(occurEquLst, Array.getIndexFirst, iSimCodeEqCompMapping);
        tmpCompIdc = List.filter1OnTrue(tmpCompIdc, intGt, 0);
        //print("getComponentsOfZeroCrossing: components: " + stringDelimitList(List.map(tmpCompIdc, intString), ",") + "\n");
      then tmpCompIdc;
    else {};
  end matchcontinue;
end getComponentsOfZeroCrossing;

protected function getComponentsIncludingTime "get the scc-idc that have an equation containing 'time' as variable
author: marcusw"
  input BackendDAE.EqSystem iSystem;
  input array<tuple<Integer,Integer,Integer>> iEqCompMapping;
  input tuple<Integer,list<Integer>> iOffsetResList; //<offset, resultList>
  output tuple<Integer,list<Integer>> oOffsetResList;
protected
  BackendDAE.EquationArray orderedEqs;
  Integer offset;
  list<Integer> resultList;
algorithm
  BackendDAE.EQSYSTEM(orderedEqs=orderedEqs) := iSystem;
  (offset, resultList) := iOffsetResList;
  ((offset, resultList, _, _)) := BackendEquation.traverseEquationArray(orderedEqs, getComponentsIncludingTime0, (offset, resultList, iEqCompMapping, 1));
  oOffsetResList := (offset, resultList);
end getComponentsIncludingTime;

protected function getComponentsIncludingTime0 "get the scc-idc that have an equation containing 'time' as variable
author: marcusw"
  input BackendDAE.Equation inEq;
  input tuple<Integer, list<Integer>, array<tuple<Integer,Integer,Integer>>, Integer> iOffsetResList; //<equation, <offset, resultList, eqCompMapping, eqIdx>>
  output BackendDAE.Equation outEq;
  output tuple<Integer, list<Integer>, array<tuple<Integer,Integer,Integer>>, Integer> oOffsetResList;
protected
  BackendDAE.Equation eq;
  Integer offset, eqIdx, sccIdx;
  list<Integer> resultList;
  array<tuple<Integer, Integer, Integer>> eqCompMapping;
  Boolean timeIsPartOfEquation;
algorithm
  (outEq,oOffsetResList) := matchcontinue(inEq,iOffsetResList)
    case (eq, (offset,resultList,eqCompMapping,eqIdx))
      equation
        ((sccIdx,_,_)) = arrayGet(eqCompMapping, eqIdx+offset);
        //print("Component " + intString(sccIdx) + "\n");
        true = BackendDAEUtil.traverseBackendDAEExpsOptEqn(SOME(eq), getComponentsIncludingTime1, false);
        resultList = sccIdx::resultList;
      then (eq, (offset,resultList,eqCompMapping,eqIdx+1));
    case (eq, (offset,resultList,eqCompMapping,eqIdx))
      then (eq, (offset,resultList,eqCompMapping,eqIdx+1));
  end matchcontinue;
end getComponentsIncludingTime0;

protected function getComponentsIncludingTime1
  input DAE.Exp inExp;
  input Boolean inB;
  output DAE.Exp e;
  output Boolean res;
algorithm
  (e,res) := match (inExp,inB)
    case (e,false)
      equation
        res = Expression.traverseCrefsFromExp(e, getComponentsIncludingTime2, false);
      then (e,res);
    else (inExp,inB);
  end match;
end getComponentsIncludingTime1;

protected function getComponentsIncludingTime2
  input DAE.ComponentRef iRef;
  input Boolean iIncludingTime;
  output Boolean oIncludingTime;
algorithm
  oIncludingTime := match(iRef, iIncludingTime)
    case (DAE.CREF_IDENT(ident="time"),_)
      equation
        //BackendDump.debugCrefStr((iRef, "\n"));
      then true;
    else
      equation
        //BackendDump.debugCrefStr((iRef, "\n"));
      then (false or iIncludingTime);
  end match;
end getComponentsIncludingTime2;

protected function getDiscreteNodes " get the taskgraph nodes that solves discrete values
author: marcusw"
  input BackendDAE.BackendDAE systIn;
  input array<tuple<Integer,Integer,Integer>> eqCompMapping;
  output list<Integer> eventNodes;
protected
  list<Integer> eqLst;
  list<tuple<Integer,Integer,Integer>> tplLst;
  BackendDAE.EqSystems systemsIn;
algorithm
  BackendDAE.DAE(eqs=systemsIn) := systIn;
  ((eqLst,_)) := List.fold(systemsIn, getDiscreteNodesEqs,({},0));
  eventNodes := getArrayTuple31(eqLst,eqCompMapping);
end getDiscreteNodes;

protected function getDiscreteNodesEqs
  input BackendDAE.EqSystem systIn;
  input tuple<list<Integer>,Integer> eventInfoIn;
  output tuple<list<Integer>,Integer> eventInfoOut;
protected
  BackendDAE.StrongComponents comps;
  BackendDAE.Variables orderedVars;
  list<Integer> eventEqs;
  list<Integer> eventEqsIn;
  Integer numOfEqs;
  Integer offset;
algorithm
  BackendDAE.EQSYSTEM(orderedEqs = BackendDAE.EQUATION_ARRAY(numberOfElement=numOfEqs),orderedVars=orderedVars,matching=BackendDAE.MATCHING(comps = comps)) := systIn;
  (eventEqsIn,offset) := eventInfoIn;
  eventEqs := getDiscreteNodesEqs1(comps,offset,orderedVars,{});
  offset := offset+numOfEqs;
  eventEqs := listAppend(eventEqs,eventEqsIn);
  eventInfoOut := (eventEqs,offset);
end getDiscreteNodesEqs;

protected function getDiscreteNodesEqs1
  input BackendDAE.StrongComponents comps;
  input Integer offset;
  input BackendDAE.Variables iOrderedVars;
  input list<Integer> discreteEqsIn;
  output list<Integer> discreteEqsOut;
algorithm
  discreteEqsOut := matchcontinue(comps,offset,iOrderedVars,discreteEqsIn)
    local
      Integer eqn;
      Integer sysCount;
      list<Integer> eventEqs;
      list<Integer> condVars;
      BackendDAE.StrongComponents rest;
      BackendDAE.StrongComponent head;
    case((head::rest),_,_,_)
      equation
        (true,eqn) = solvesDiscreteValue(head, iOrderedVars);
        eqn = eqn+offset;
        eventEqs = getDiscreteNodesEqs1(rest,offset,iOrderedVars,eqn::discreteEqsIn);
      then
        eventEqs;
    case((_::rest),_,_,_)
      equation
        eventEqs = getDiscreteNodesEqs1(rest,offset,iOrderedVars,discreteEqsIn);
      then
        eventEqs;
    case({},_,_,_)
      then
        discreteEqsIn;
  end matchcontinue;
end getDiscreteNodesEqs1;

protected function solvesDiscreteValue
  input BackendDAE.StrongComponent inComp;
  input BackendDAE.Variables iOrderedVars;
  output Boolean oSolvesDiscreteValue;
  output Integer oFirstEqIdx;
algorithm
  (oSolvesDiscreteValue,oFirstEqIdx) := matchcontinue(inComp,iOrderedVars)
    local
      Integer eqn, var;
      list<Integer> vars, eqns;
      list<BackendDAE.Var> backendVars;
      BackendDAE.Var backendVar;
      Boolean solvesDiscreteValue;
    case(BackendDAE.SINGLEEQUATION(var=var,eqn=eqn),_)
      equation
        //print("Var of single equation: " + intString(var) + "\n");
        backendVar = BackendVariable.getVarAt(iOrderedVars, var);
        solvesDiscreteValue = BackendVariable.isVarDiscrete(backendVar);
      then (solvesDiscreteValue,eqn);
    case(BackendDAE.EQUATIONSYSTEM(vars=vars,eqns=eqns),_)
      equation
        //print("Vars of single equation system: " + stringDelimitList(List.map(vars, intString), ",") + "\n");
        backendVars = List.map1r(vars, BackendVariable.getVarAt, iOrderedVars);
        solvesDiscreteValue = BackendVariable.hasDiscreteVar(backendVars);
        eqn = List.first(eqns);
      then (solvesDiscreteValue,eqn);
    case(BackendDAE.SINGLEARRAY(vars=vars,eqn=eqn),_)
      equation
        //print("Vars of single array: " + stringDelimitList(List.map(vars, intString), ",") + "\n");
        backendVars = List.map1r(vars, BackendVariable.getVarAt, iOrderedVars);
        solvesDiscreteValue = BackendVariable.hasDiscreteVar(backendVars);
      then (solvesDiscreteValue,eqn);
    case(BackendDAE.SINGLEWHENEQUATION(vars=vars,eqn=eqn),_)
      equation
        //print("Vars of single when equation: " + stringDelimitList(List.map(vars, intString), ",") + "\n");
        backendVars = List.map1r(vars, BackendVariable.getVarAt, iOrderedVars);
        solvesDiscreteValue = BackendVariable.hasDiscreteVar(backendVars);
      then (solvesDiscreteValue,eqn);
    case(BackendDAE.SINGLECOMPLEXEQUATION(vars=vars,eqn=eqn),_)
      equation
        //print("Vars of single complex equation: " + stringDelimitList(List.map(vars, intString), ",") + "\n");
        backendVars = List.map1r(vars, BackendVariable.getVarAt, iOrderedVars);
        solvesDiscreteValue = BackendVariable.hasDiscreteVar(backendVars);
      then (solvesDiscreteValue,eqn);
    case(BackendDAE.SINGLEALGORITHM(vars=vars,eqn=eqn),_)
      equation
        //print("Vars of single algorithm: " + stringDelimitList(List.map(vars, intString), ",") + "\n");
        backendVars = List.map1r(vars, BackendVariable.getVarAt, iOrderedVars);
        solvesDiscreteValue = BackendVariable.hasDiscreteVar(backendVars);
      then (solvesDiscreteValue,eqn);
    case(BackendDAE.SINGLEIFEQUATION(vars=vars,eqn=eqn),_)
      equation
        //print("Vars of single if equation: " + stringDelimitList(List.map(vars, intString), ",") + "\n");
        backendVars = List.map1r(vars, BackendVariable.getVarAt, iOrderedVars);
        solvesDiscreteValue = BackendVariable.hasDiscreteVar(backendVars);
      then (solvesDiscreteValue,eqn);
  else (false,-1);
  end matchcontinue;
end solvesDiscreteValue;


//------------------------------------------
//Methods to write blt-structure as xml-file
//------------------------------------------
public uniontype GraphDumpOptions
  record GRAPHDUMPOPTIONS
    Boolean visualizeCriticalPath;
    Boolean visualizeTaskStartAndFinishTime;
    Boolean visualizeTaskCalcTime;
    Boolean visualizeCommTime;
  end GRAPHDUMPOPTIONS;
end GraphDumpOptions;

public function dumpTaskGraph
  input BackendDAE.BackendDAE dae;
  input String fileName;
protected
  String name;
  TaskGraph taskGraph;
  TaskGraphMeta taskGraphData;
  array<tuple<Integer,Integer,Real>> schedulerInfo;
  array<list<Integer>> sccSimEqMapping;
algorithm
  (taskGraph,taskGraphData) := HpcOmTaskGraph.createTaskGraph(dae);
  name := ("TaskGraph_"+fileName+".graphml");
  schedulerInfo := arrayCreate(arrayLength(taskGraph), (-1,-1,-1.0));
  sccSimEqMapping := arrayCreate(arrayLength(taskGraph),{-1});
  HpcOmTaskGraph.dumpAsGraphMLSccLevel(taskGraph, taskGraphData,dae, name, "", {}, {}, sccSimEqMapping, schedulerInfo, HpcOmTaskGraph.GRAPHDUMPOPTIONS(false,false,true,true));
end dumpTaskGraph;

public function dumpBipartiteGraph
  input BackendDAE.BackendDAE dae;
  input String fileName;
protected
  BackendDAE.Variables vars;
  BackendDAE.EquationArray eqs;
  BackendDAE.EqSystems eqSysts;
  BackendDAE.IncidenceMatrix m,mT;
  list<BackendDAE.Equation> eqLst;
  list<BackendDAE.Var> varLst;
  list<tuple<Boolean,String>> varAtts,eqAtts;
algorithm
  BackendDAE.DAE(eqs=eqSysts) := dae;
  eqLst := List.flatten(List.map(List.map(eqSysts,BackendEquation.getEqnsFromEqSystem),BackendEquation.equationList));
  varLst := List.flatten(List.map(List.map(eqSysts,BackendVariable.daeVars),BackendVariable.varList));
  vars := BackendVariable.listVar1(varLst);
  eqs := BackendEquation.listEquation(eqLst);
  // build the incidence matrix for the whole System
  (m,mT) := BackendDAEUtil.incidenceMatrixDispatch(vars,eqs, BackendDAE.NORMAL());
  m := Array.map(m,function List.filter1OnTrue(inFilterFunc=intGt,inArg1=0));
  varAtts := List.threadMap(List.fill(false,listLength(varLst)),List.fill("",listLength(varLst)),Util.makeTuple);
  eqAtts := List.threadMap(List.fill(false,listLength(eqLst)),List.fill("",listLength(eqLst)),Util.makeTuple);
  HpcOmEqSystems.dumpEquationSystemBipartiteGraph2(vars,eqs,m,varAtts,eqAtts,"BipartiteGraph_"+fileName);
end dumpBipartiteGraph;

public function dumpAsGraphMLSccLevel "author: marcusw, waurich
  Write out the given graph as a graphml file."
  input TaskGraph iGraph;
  input TaskGraphMeta iGraphData;
  input BackendDAE.BackendDAE iBackendDAE;
  input String iFileName;
  input String iCriticalPathInfo; //Critical path as String
  input list<tuple<Integer,Integer>> iCriticalPath; //Critical path as list of edges
  input list<tuple<Integer,Integer>> iCriticalPathWoC; //Critical path without communciation as list of edges
  input array<list<Integer>> iSccSimEqMapping; //maps each scc to simEqSystems
  input array<tuple<Integer,Integer,Real>> iSchedulerInfo; //maps each Task to <threadId, orderId, startCalcTime>
  input GraphDumpOptions iGraphDumpOptions; //Options to specify the output
protected
  GraphML.GraphInfo graphInfo;
algorithm
  graphInfo := convertToGraphMLSccLevel(iGraph,iGraphData,iBackendDAE,iCriticalPathInfo,iCriticalPath,iCriticalPathWoC,iSccSimEqMapping,iSchedulerInfo,iGraphDumpOptions);
  GraphML.dumpGraph(graphInfo, iFileName);
end dumpAsGraphMLSccLevel;

public function convertToGraphMLSccLevel "author: marcusw, waurich
  Convert the given graph into a graphml-structure."
  input TaskGraph iGraph;
  input TaskGraphMeta iGraphData;
  input BackendDAE.BackendDAE iBackendDAE;
  input String iCriticalPathInfo; //Critical path as String
  input list<tuple<Integer,Integer>> iCriticalPath; //Critical path as list of edges
  input list<tuple<Integer,Integer>> iCriticalPathWoC; //Critical path without communciation as list of edges
  input array<list<Integer>> iSccSimEqMapping; //maps each scc to simEqSystems
  input array<tuple<Integer,Integer,Real>> iSchedulerInfo; //maps each Task to <threadId, orderId, startCalcTime>
  input GraphDumpOptions iGraphDumpOptions; //Options to specify the output
  output GraphML.GraphInfo oGraphInfo;
protected
  Integer graphIdx;
  array<String> annotationInfo;
  GraphML.GraphInfo graphInfo;
algorithm
  graphInfo := GraphML.createGraphInfo();
  (graphInfo, (_,graphIdx)) := GraphML.addGraph("TaskGraph", true, graphInfo);
  annotationInfo := arrayCreate(arrayLength(iGraph),"uncomment in HpcOmTaskGraph and +showAnnotations");
  //annotationInfo := setAnnotationsForTasks(iGraphData,backendDAE,annotationInfo);
  oGraphInfo := convertToGraphMLSccLevelSubgraph(iGraph,iGraphData,iCriticalPathInfo,iCriticalPath,iCriticalPathWoC,iSccSimEqMapping,iSchedulerInfo,annotationInfo,graphIdx,iGraphDumpOptions,graphInfo);
end convertToGraphMLSccLevel;

public function convertToGraphMLSccLevelSubgraph "author: marcusw, waurich
  Convert the given graph into a subgraph of the graphml-structure."
  input TaskGraph iGraph;
  input TaskGraphMeta iGraphData;
  input String iCriticalPathInfo; //Critical path as String
  input list<tuple<Integer,Integer>> iCriticalPath; //Critical path as list of edges
  input list<tuple<Integer,Integer>> iCriticalPathWoC; //Critical path without communciation as list of edges
  input array<list<Integer>> iSccSimEqMapping; //maps each scc to simEqSystems
  input array<tuple<Integer,Integer,Real>> iSchedulerInfo; //maps each Task to <threadId, orderId, startCalcTime>
  input array<String> iAnnotationInfo;  //annotations for the variables in a task
  input Integer iGraphIdx;
  input GraphDumpOptions iGraphDumpOptions; //Options to specify the output
  input GraphML.GraphInfo iGraphInfo;
  output GraphML.GraphInfo oGraphInfo;
protected
  GraphML.GraphInfo graphInfo;
  Integer nameAttIdx, calcTimeAttIdx, opCountAttIdx, yCoordAttIdx, taskIdAttIdx, commCostAttIdx,
          commVarsAttIdx, commVarsIntAttIdx, commVarsFloatAttIdx, commVarsBoolAttIdx, critPathAttIdx,
          simCodeEqAttIdx, threadIdAttIdx, taskNumberAttIdx, annotAttIdx, compsIdAttIdx, partOfEventAttIdx, partOfOdeAttIdx, removedCompAttIdx;
  list<Integer> nodeIdc;
algorithm
  oGraphInfo := match(iGraph, iGraphData, iCriticalPathInfo, iCriticalPath, iCriticalPathWoC, iSccSimEqMapping, iSchedulerInfo, iAnnotationInfo, iGraphIdx, iGraphDumpOptions, iGraphInfo)
    case(_,_,_,_,_,_,_,_,_,_,_)
      equation
        (graphInfo,(_,nameAttIdx)) = GraphML.addAttribute("", "Name", GraphML.TYPE_STRING(), GraphML.TARGET_NODE(), iGraphInfo);
        (graphInfo,(_,opCountAttIdx)) = GraphML.addAttribute("-1", "Operations", GraphML.TYPE_INTEGER(), GraphML.TARGET_NODE(), graphInfo);
        (graphInfo,(_,calcTimeAttIdx)) = GraphML.addAttribute("-1", "CalcTime", GraphML.TYPE_DOUBLE(), GraphML.TARGET_NODE(), graphInfo);
        (graphInfo,(_,taskIdAttIdx)) = GraphML.addAttribute("", "TaskID", GraphML.TYPE_STRING(), GraphML.TARGET_NODE(), graphInfo);
        (graphInfo,(_,compsIdAttIdx)) = GraphML.addAttribute("", "Components", GraphML.TYPE_STRING(), GraphML.TARGET_NODE(), graphInfo);
        (graphInfo,(_,yCoordAttIdx)) = GraphML.addAttribute("17", "yCoord", GraphML.TYPE_INTEGER(), GraphML.TARGET_NODE(), graphInfo);
        (graphInfo,(_,simCodeEqAttIdx)) = GraphML.addAttribute("", "SimCodeEqs", GraphML.TYPE_STRING(), GraphML.TARGET_NODE(), graphInfo);
        (graphInfo,(_,threadIdAttIdx)) = GraphML.addAttribute("", "ThreadId", GraphML.TYPE_STRING(), GraphML.TARGET_NODE(), graphInfo);
        (graphInfo,(_,taskNumberAttIdx)) = GraphML.addAttribute("-1", "TaskNumber", GraphML.TYPE_INTEGER(), GraphML.TARGET_NODE(), graphInfo);
        (graphInfo,(_,commCostAttIdx)) = GraphML.addAttribute("-1", "CommCost", GraphML.TYPE_DOUBLE(), GraphML.TARGET_EDGE(), graphInfo);
        (graphInfo,(_,commVarsAttIdx)) = GraphML.addAttribute("-1", "CommVars", GraphML.TYPE_INTEGER(), GraphML.TARGET_EDGE(), graphInfo);
        (graphInfo,(_,commVarsIntAttIdx)) = GraphML.addAttribute("-1", "CommVarsInt", GraphML.TYPE_INTEGER(), GraphML.TARGET_EDGE(), graphInfo);
        (graphInfo,(_,commVarsFloatAttIdx)) = GraphML.addAttribute("-1", "CommVarsFloat", GraphML.TYPE_INTEGER(), GraphML.TARGET_EDGE(), graphInfo);
        (graphInfo,(_,commVarsBoolAttIdx)) = GraphML.addAttribute("-1", "CommVarsBool", GraphML.TYPE_INTEGER(), GraphML.TARGET_EDGE(), graphInfo);
        (graphInfo,(_,annotAttIdx)) = GraphML.addAttribute("annotation", "Annotations", GraphML.TYPE_STRING(), GraphML.TARGET_NODE(), graphInfo);
        (graphInfo,(_,critPathAttIdx)) = GraphML.addAttribute("", "CriticalPath", GraphML.TYPE_STRING(), GraphML.TARGET_GRAPH(), graphInfo);
        (graphInfo,(_,partOfEventAttIdx)) = GraphML.addAttribute("false", "IsPartOfEventSystem", GraphML.TYPE_BOOLEAN(), GraphML.TARGET_NODE(), graphInfo);
        (graphInfo,(_,partOfOdeAttIdx)) = GraphML.addAttribute("false", "IsPartOfOdeSystem", GraphML.TYPE_BOOLEAN(), GraphML.TARGET_NODE(), graphInfo);
        (graphInfo,(_,removedCompAttIdx)) = GraphML.addAttribute("false", "IsRemovedComponent", GraphML.TYPE_BOOLEAN(), GraphML.TARGET_NODE(), graphInfo);
        graphInfo = GraphML.addGraphAttributeValue((critPathAttIdx, iCriticalPathInfo), iGraphIdx, graphInfo);
        nodeIdc = List.intRange(arrayLength(iGraph));
        ((graphInfo,_)) = List.fold(nodeIdc, function addNodeToGraphML(
                                     tGraphDataTuple=(iGraph, iGraphData),
                                     attIdc=(nameAttIdx,opCountAttIdx,calcTimeAttIdx,taskIdAttIdx,compsIdAttIdx,yCoordAttIdx,commCostAttIdx,commVarsAttIdx,
                                      commVarsIntAttIdx,commVarsFloatAttIdx,commVarsBoolAttIdx,simCodeEqAttIdx,threadIdAttIdx,taskNumberAttIdx,annotAttIdx,
                                      partOfEventAttIdx, partOfOdeAttIdx, removedCompAttIdx),
                                     sccSimEqMapping=iSccSimEqMapping,
                                     iSchedulerInfoCritPath=(iCriticalPath,iCriticalPathWoC,iSchedulerInfo, iAnnotationInfo),
                                     iGraphDumpOptions=iGraphDumpOptions),
                                     (graphInfo,iGraphIdx));
      then graphInfo;
  end match;
end convertToGraphMLSccLevelSubgraph;

protected function addNodeToGraphML "author: marcusw, waurich
  Adds the given node to the given graph."
  input Integer nodeIdx;
  input tuple<TaskGraph, TaskGraphMeta> tGraphDataTuple;
  input tuple<Integer,Integer,Integer,Integer,Integer,Integer,Integer,Integer,Integer,Integer,Integer,Integer,Integer,Integer,Integer,Integer,Integer,Integer> attIdc;
  //Attribute index for <nameAttIdx,opCountAttIdx, calcTimeAttIdx, taskIdAttIdx, compsIdAttIdx, yCoordAttIdx, commCostAttIdx, commVarsAttIdx, commVarsAttIntIdx,
  //                     commVarsAttFloatIdx, commVarsAttBoolIdx, simCodeEqAttIdx, threadIdAttIdx, taskNumberAttIdx, annotationAttIdx, partOfEventAttIdx, partOfOdeAttIdx, removedCompAttIdx>
  input array<list<Integer>> sccSimEqMapping;
  input tuple<list<tuple<Integer,Integer>>,list<tuple<Integer,Integer>>,array<tuple<Integer,Integer,Real>>,array<String>> iSchedulerInfoCritPath; //<criticalPath,criticalPathWoC,schedulerInfo,annotationInfo>
  input GraphDumpOptions iGraphDumpOptions; //Options to specify the output
  input tuple<GraphML.GraphInfo,Integer> iGraph;
  output tuple<GraphML.GraphInfo,Integer> oGraph; //<GraphInfo, GraphIdx>
protected
  TaskGraph tGraphIn;
  TaskGraphMeta tGraphDataIn;
  GraphML.GraphInfo tmpGraph;
  Integer graphIdx;
  Integer opCount, nameAttIdx, calcTimeAttIdx, opCountAttIdx, taskIdAttIdx, compsIdAttIdx, yCoordAttIdx, commCostAttIdx, commVarsAttIdx, commVarsAttIntIdx;
  Integer commVarsAttFloatIdx, commVarsAttBoolIdx, yCoord, simCodeEqAttIdx, threadIdAttIdx, taskNumberAttIdx, annotationAttIdx;
  Integer partOfEventAttIdx, partOfOdeAttIdx, removedCompAttIdx;
  Real calcTime, taskFinishTime, taskStartTime;
  Integer primalComp;
  list<Integer> childNodes;
  list<Integer> components;
  list<Integer> simCodeEqs;
  array<tuple<Integer,Integer,Integer>>  eqCompMapping;
  array<tuple<Integer,Real>> exeCosts;
  array<Integer> nodeMark;
  array<list<Integer>> inComps;
  array<String> compNames;
  array<String> compDescs;
  array<String> annotationInfo;
  array<Communications> commCosts;
  String calcTimeString, opCountString, yCoordString, taskFinishTimeString, taskStartTimeString;
  String compText;
  String compsText;
  String description;
  String nodeDesc;
  String componentsString;
  String simCodeEqString;
  String threadIdxString, taskNumberString;
  String annotationString;
  Integer schedulerThreadId, schedulerTaskNumber;
  list<GraphML.NodeLabel> nodeLabels;
  array<tuple<Integer,Integer,Real>> schedulerInfo;
  list<tuple<Integer,Integer>> criticalPath, criticalPathWoC;
  Boolean visualizeTaskStartAndFinishTime;
  Boolean visualizeTaskCalcTime;
  Boolean isPartOfODESystem, isPartOfEventSystem, isRemovedComponent;
  array<ComponentInfo> compInformations;
algorithm
  (tmpGraph,graphIdx) := iGraph;
  if(intGt(nodeIdx, 0)) then
    (tGraphIn, tGraphDataIn) := tGraphDataTuple;
    TASKGRAPHMETA(inComps=inComps, compNames=compNames, compDescs=compDescs, exeCosts=exeCosts, nodeMark=nodeMark, compInformations=compInformations) := tGraphDataIn;
    (nameAttIdx, opCountAttIdx, calcTimeAttIdx, taskIdAttIdx, compsIdAttIdx, yCoordAttIdx, commCostAttIdx, commVarsAttIdx, commVarsAttIntIdx, commVarsAttFloatIdx, commVarsAttBoolIdx, simCodeEqAttIdx, threadIdAttIdx, taskNumberAttIdx, annotationAttIdx, partOfEventAttIdx, partOfOdeAttIdx, removedCompAttIdx) := attIdc;
    (criticalPath,criticalPathWoC,schedulerInfo,annotationInfo) := iSchedulerInfoCritPath;
    GRAPHDUMPOPTIONS(visualizeTaskStartAndFinishTime=visualizeTaskStartAndFinishTime, visualizeTaskCalcTime=visualizeTaskCalcTime) := iGraphDumpOptions;
    components := arrayGet(inComps,nodeIdx);
    ((isPartOfODESystem, isPartOfEventSystem, isRemovedComponent)) := getNodeMembershipByComponents(components, compInformations);

    if(intNe(listLength(components), 1)) then
      primalComp := List.last(components);
      simCodeEqs := List.flatten(List.map1(components, Array.getIndexFirst, sccSimEqMapping));
      nodeDesc := stringDelimitList(List.map1(components, Array.getIndexFirst, compDescs), "\n");// arrayGet(compDescs,primalComp);
      ((opCount,calcTime)) := List.fold1(components, addNodeToGraphML1, exeCosts, (0,0.0));
    else
      primalComp := listGet(components,1);
      simCodeEqs := arrayGet(sccSimEqMapping,primalComp);
      nodeDesc := arrayGet(compDescs,primalComp);
      ((_,calcTime)) := arrayGet(exeCosts,primalComp);
      ((opCount,calcTime)) := arrayGet(exeCosts,primalComp);
    end if;

    compText := arrayGet(compNames,primalComp);
    compsText := "{" + stringDelimitList(List.map(components, intString), ",") + "}";
    annotationString := arrayGet(annotationInfo,nodeIdx);
    calcTimeString := realString(calcTime);
    yCoord := arrayGet(nodeMark,nodeIdx)*100;
    opCountString := intString(opCount);
    yCoordString := intString(yCoord);
    childNodes := arrayGet(tGraphIn,nodeIdx);
    simCodeEqString := stringDelimitList(List.map(simCodeEqs,intString),", ");
    //componentsString := List.fold(components, addNodeToGraphML2, " ");
    componentsString := (" "+intString(nodeIdx)+" ");
    ((schedulerThreadId,schedulerTaskNumber,taskFinishTime)) := arrayGet(schedulerInfo,nodeIdx);
    taskStartTime := realSub(taskFinishTime,calcTime);
    threadIdxString := "Th " + intString(schedulerThreadId);
    taskNumberString := intString(schedulerTaskNumber);
    calcTimeString := System.snprintff("%.0f", 25, calcTime);
    taskFinishTimeString := System.snprintff("%.0f", 25, taskFinishTime);
    taskStartTimeString := System.snprintff("%.0f", 25, taskStartTime);
    nodeLabels := {GraphML.NODELABEL_INTERNAL(componentsString, NONE(), GraphML.FONTPLAIN())};
    nodeLabels := if visualizeTaskCalcTime then GraphML.NODELABEL_CORNER(calcTimeString, SOME(GraphML.COLOR_YELLOW), GraphML.FONTBOLD(), "se")::nodeLabels else nodeLabels;
    nodeLabels := if visualizeTaskStartAndFinishTime then listAppend(nodeLabels, {GraphML.NODELABEL_CORNER(taskStartTimeString, SOME(GraphML.COLOR_CYAN), GraphML.FONTBOLD(), "nw"), GraphML.NODELABEL_CORNER(taskFinishTimeString, SOME(GraphML.COLOR_PINK), GraphML.FONTBOLD(), "sw")}) else nodeLabels;
    (tmpGraph,(_,_)) := GraphML.addNode("Node" + intString(nodeIdx),
                                      GraphML.COLOR_ORANGE,
                                      nodeLabels,
                                      GraphML.RECTANGLE(),
                                      SOME(nodeDesc),
                                      {
                                        ((nameAttIdx,compText)),((calcTimeAttIdx,calcTimeString)),((opCountAttIdx, opCountString)),((taskIdAttIdx,componentsString)),((compsIdAttIdx,compsText)),
                                        ((yCoordAttIdx,yCoordString)),((simCodeEqAttIdx,simCodeEqString)),((threadIdAttIdx,threadIdxString)),((taskNumberAttIdx,taskNumberString)),
                                        ((annotationAttIdx,annotationString)), ((partOfEventAttIdx, boolString(isPartOfODESystem))), ((partOfOdeAttIdx, boolString(isPartOfEventSystem))), ((removedCompAttIdx, boolString(isRemovedComponent)))
                                      },
                                      graphIdx,
                                      tmpGraph);
    tmpGraph := List.fold(childNodes, function addDepToGraph(
        parentIdx=nodeIdx,
        tGraphDataIn=tGraphDataIn,
        iCommAttIdc=(commCostAttIdx, commVarsAttIdx, commVarsAttIntIdx, commVarsAttFloatIdx, commVarsAttBoolIdx),
        iCriticalPathEdges=(criticalPath,criticalPathWoC),
        iGraphDumpOptions=iGraphDumpOptions),
        tmpGraph);
  else
    Error.addMessage(Error.INTERNAL_ERROR, {"function addNodeToGraphML failed."});
  end if;
  oGraph := ((tmpGraph,graphIdx));
end addNodeToGraphML;

protected function addNodeToGraphML1 "author: marcusw
  Adds the execution costs of the given scc to the exeCostsIn-values."
  input Integer compIdx;
  input array<tuple<Integer,Real>> exeCosts;
  input tuple<Integer,Real> exeCostsIn;
  output tuple<Integer,Real> exeCostsOut;
protected
  Integer opCount, opCountIn;
  Real exeTimeIn, exeTime;
algorithm
  (opCountIn,exeTimeIn) := exeCostsIn;
  ((opCount,exeTime)) := arrayGet(exeCosts,compIdx);
  exeCostsOut := ((opCountIn+opCount,realAdd(exeTimeIn,exeTime)));
end addNodeToGraphML1;

protected function addDepToGraph "author: marcusw
  Adds a new edge between the component-nodes with index comp1Idx and comp2Idx to the graph."
  input Integer childIdx;
  input Integer parentIdx;
  input TaskGraphMeta tGraphDataIn;
  input tuple<Integer,Integer, Integer, Integer, Integer> iCommAttIdc; //<%(commCostAttIdx, commVarsAttIdx, commVarsAttIntIdx, commVarsAttFloatIdx, commVarsAttBoolIdx)%>
  input tuple<list<tuple<Integer,Integer>>,list<tuple<Integer,Integer>>> iCriticalPathEdges; //<%criticalPathEdges, criticalPathEdgesWoC%>
  input GraphDumpOptions iGraphDumpOptions; //Options to specify the output
  input GraphML.GraphInfo iGraph;
  output GraphML.GraphInfo oGraph;
protected
  array<Communications> commCosts;
  list<Integer> integerVars,floatVars,booleanVars;
  Integer commCostAttIdx, commVarsAttIdx, commVarsAttIntIdx, commVarsAttFloatIdx, commVarsAttBoolIdx;
  Integer numOfCommVars, numOfCommVarsInt, numOfCommVarsFloat, numOfCommVarsBool, primalCompParent, primalCompChild;
  Real commCost;
  String refSccCountStr, commCostString, numOfCommVarsString, numOfCommVarsIntString, numOfCommVarsFloatString, numOfCommVarsBoolString;
  array<list<Integer>> inComps;
  array<Integer> nodeMark;
  list<Integer> components;
  GraphML.GraphInfo tmpGraph;
  list<tuple<Integer,Integer>> criticalPathEdges, criticalPathEdgesWoC;
  String edgeColor = GraphML.COLOR_BLACK;
  Boolean visualizeCriticalPath;
  Boolean visualizeCommTime;
  list<GraphML.EdgeLabel> edgeLabels;
  Real lineWidth;
algorithm
  TASKGRAPHMETA(commCosts=commCosts, nodeMark=nodeMark, inComps=inComps) := tGraphDataIn;
  (commCostAttIdx, commVarsAttIdx, commVarsAttIntIdx, commVarsAttFloatIdx, commVarsAttBoolIdx) := iCommAttIdc;
  (criticalPathEdges, criticalPathEdgesWoC) := iCriticalPathEdges;
  GRAPHDUMPOPTIONS(visualizeCriticalPath=visualizeCriticalPath,visualizeCommTime=visualizeCommTime) := iGraphDumpOptions;

  if(List.exist1(criticalPathEdges, compareIntTuple2, (parentIdx, childIdx))) then
    lineWidth := GraphML.LINEWIDTH_BOLD;
    edgeColor := if visualizeCriticalPath then GraphML.COLOR_GRAY else edgeColor;
  else
    lineWidth := GraphML.LINEWIDTH_STANDARD;
  end if;

  COMMUNICATION(numberOfVars=numOfCommVars,integerVars=integerVars,floatVars=floatVars,booleanVars=booleanVars,requiredTime=commCost) := getCommCostBetweenNodes(parentIdx,childIdx,tGraphDataIn);
  numOfCommVarsString := intString(numOfCommVars);
  numOfCommVarsIntString := intString(listLength(integerVars));
  numOfCommVarsFloatString := intString(listLength(floatVars));
  numOfCommVarsBoolString := intString(listLength(booleanVars));
  commCostString := System.snprintff("%.0f", 25, commCost);
  edgeLabels := if visualizeCommTime then {GraphML.EDGELABEL(commCostString, SOME(edgeColor), GraphML.FONTSIZE_STANDARD)} else {};
  (tmpGraph,(_,_)) := GraphML.addEdge("Edge" + intString(parentIdx) + intString(childIdx),
                                         "Node" + intString(childIdx), "Node" + intString(parentIdx),
                                          edgeColor,
                                          GraphML.LINE(),
                                          lineWidth,
                                          false,
                                          edgeLabels,
                                          (GraphML.ARROWNONE(),GraphML.ARROWSTANDART()),
                                          {(commCostAttIdx, commCostString),(commVarsAttIdx, numOfCommVarsString),(commVarsAttIntIdx,numOfCommVarsIntString),(commVarsAttFloatIdx,numOfCommVarsFloatString),(commVarsAttBoolIdx,numOfCommVarsBoolString)},
                                          iGraph);
  oGraph := tmpGraph;
end addDepToGraph;

protected function getNodeMembershipByComponents "author: marcusw
  Get the information of a node was removed or belongs to the ode or event-system."
  input list<Integer> iNodeComponents;
  input array<ComponentInfo> iCompInformations;
  output tuple<Boolean, Boolean, Boolean> oMembership; //<isPartOfODESystem, isPartOfEventSystem, isRemovedComponent>
protected
  Boolean isPartOfODESystem, isPartOfEventSystem, isRemovedComponent;
  Integer compIdx;
  ComponentInfo tmpComponentInformation;
algorithm
  tmpComponentInformation := COMPONENTINFO(false, false, false);
  for compIdx in iNodeComponents loop
    tmpComponentInformation := combineComponentInformations(arrayGet(iCompInformations, compIdx), tmpComponentInformation);
  end for;
  COMPONENTINFO(isPartOfODESystem, isPartOfEventSystem, isRemovedComponent) := tmpComponentInformation;
  oMembership := (isPartOfODESystem, isPartOfEventSystem, isRemovedComponent);
end getNodeMembershipByComponents;

//-----------------
//  Print functions
//-----------------

public function printTaskGraph " prints the adjacencylist of the TaskGraph.
author:Waurich TUD 2013-07"
  input TaskGraph graphIn;
protected
  list<list<Integer>> graphLst;
algorithm
  print("\n");
  print("--------------------------------\n");
  print("TASKGRAPH\n");
  print("--------------------------------\n");
  graphLst := arrayList(graphIn);
  dumpAdjacencyLst(graphLst,1);
  print("\n");
end printTaskGraph;

public function dumpAdjacencyLst " prints the adjacencyLst.
author:Waurich TUD 2013-07"
  input list<list<Integer>> inIntegerLstLst;
  input Integer rowIndex;
algorithm
  _ := match (inIntegerLstLst,rowIndex)
    local
      list<Integer> row;
      list<list<Integer>> rows;
    case ({},_) then ();
    case ((row :: rows),_)
      equation
        print(intString(rowIndex));print(":");
        dumpAdjacencyRow(row);
        dumpAdjacencyLst(rows,rowIndex+1);
      then
        ();
  end match;
end dumpAdjacencyLst;

public function dumpAdjacencyRow
"author: PA
  Helper function to dumpIncidenceMatrix2."
  input list<Integer> inIntegerLst;
algorithm
  _ := match (inIntegerLst)
    local
      String s;
      Integer x;
      list<Integer> xs;
    case ({})
      equation
        print("\n");
      then
        ();
    case ((x :: xs))
      equation
        s = intString(x);
        print(s);
        print(" ");
        dumpAdjacencyRow(xs);
      then
        ();
  end match;
end dumpAdjacencyRow;

public function printTaskGraphMeta " prints all data from TaskGraphMeta.
author: Waurich TUD 2013-06"
  input TaskGraphMeta metaDataIn;
protected
  array<list<Integer>> inComps;
  array<tuple<Integer, Integer, Integer>>  varCompMapping;
  array<tuple<Integer,Integer,Integer>>  eqCompMapping;
  array<String> compNames;
  array<String> compDescs;
  array<tuple<Integer,Real>> exeCosts;
  array<Communications> commCosts;
  array<Integer> nodeMark;
  array<list<Integer>> compParamMapping;
  array<ComponentInfo> compInformations;
algorithm
  TASKGRAPHMETA(inComps=inComps, varCompMapping=varCompMapping, eqCompMapping=eqCompMapping, compParamMapping=compParamMapping, compNames=compNames, compDescs=compDescs, exeCosts=exeCosts, commCosts=commCosts, nodeMark=nodeMark, compInformations=compInformations) := metaDataIn;
  print("\n");
  print("--------------------------------\n");
  print("TASKGRAPH METADATA\n");
  print("--------------------------------\n");
  print(intString(arrayLength(inComps))+" nodes include components:\n");
  printInComps(inComps);
  print(intString(arrayLength(varCompMapping))+" vars are solved in the nodes \n");
  printVarCompMapping(varCompMapping);
  print(intString(arrayLength(eqCompMapping))+" equations are computed in the nodes \n");
  printEqCompMapping(eqCompMapping);
  print(intString(arrayLength(compParamMapping))+" parameters are part of the components \n");
  printCompParamMapping(compParamMapping);
  print("the names of the components \n");
  printComponentNames(compNames);
  print("the description of the node\n");
  printCompDescs(compDescs);
  print("the execution costs of the nodes\n");
  printExeCosts(exeCosts);
  print("the communication costs of the nodes\n");
  printCommCosts(commCosts);
  print("the nodeMark of the nodes\n");
  printNodeMarks(nodeMark);
  print("the component informations are\n");
  printComponentInformations(compInformations);
  print("\n");
end printTaskGraphMeta;

public function printInComps " prints the information about the assigned components to a taskgraph node.
author:Waurich TUD 2013-06"
  input array<list<Integer>> iInComps;
protected
  Integer nodeIdx;
  list<Integer> compRow;
algorithm
  for nodeIdx in 1:arrayLength(iInComps) loop
    compRow := arrayGet(iInComps,nodeIdx);
    print("node " + intString(nodeIdx) + " solves components: " + stringDelimitList(List.map(compRow,intString),", ") + "\n");
  end for;
  print("--------------------------------\n");
end printInComps;

public function printVarCompMapping " prints the information about how the vars are assigned to the graph nodes
author: Waurich TUD 2013-07 / mwalther"
  input array<tuple<Integer, Integer, Integer>> iVarCompMapping;
protected
  Integer varIdx, comp, eqSysIdx, varOffset;
algorithm
  for varIdx in 1:arrayLength(iVarCompMapping) loop
    ((comp,eqSysIdx,varOffset)) := arrayGet(iVarCompMapping,varIdx);
    print("variable " + intString(varIdx-varOffset) + " (offset: " + intString(varOffset) + ") of equation system " + intString(eqSysIdx) + " is solved in component: " + intString(comp) + "\n");
  end for;
  print("--------------------------------\n");
end printVarCompMapping;

public function printEqCompMapping " prints the information about which equations are assigned to the graph nodes
author: Waurich TUD 2013-07 / mwalther"
  input array<tuple<Integer,Integer,Integer>> iEqCompMapping;
protected
  Integer eqIdx, comp, eqSysIdx, eqOffset;
algorithm
  for eqIdx in 1:arrayLength(iEqCompMapping) loop
    ((comp,eqSysIdx,eqOffset)) := arrayGet(iEqCompMapping,eqIdx);
    print("equation " + intString(eqIdx) + " (offset: " + intString(eqOffset) + ") of equation system " + intString(eqSysIdx) + " is computed in component: " + intString(comp) + "\n");
  end for;
  print("--------------------------------\n");
end printEqCompMapping;

public function printCompParamMapping "prints the information which components contains which parameters
author: marcusw"
  input array<list<Integer>> iCompParamMapping;
protected
  Integer compIdx;
  list<Integer> params;
algorithm
  for compIdx in 1:arrayLength(iCompParamMapping) loop
    params := arrayGet(iCompParamMapping,compIdx);
    print("component " + intString(compIdx) + " needs the parameters: " + stringDelimitList(List.map(params, intString), ",") + "\n");
  end for;
  print("--------------------------------\n");
end printCompParamMapping;

protected function printComponentNames "prints the component names of the taskgraph components
author: Waurich TUD 2013-07 / mwalther"
  input array<String> iCompNames;
protected
  Integer compIdx;
  String compName;
algorithm
  for compIdx in 1:arrayLength(iCompNames) loop
    compName := arrayGet(iCompNames,compIdx);
    print("component " + intString(compIdx) + " is named " + compName + "\n");
  end for;
  print("--------------------------------\n");
end printComponentNames;

protected function printCompDescs "prints the information about the description of the taskgraph nodes for the .graphml file.
author: Waurich TUD 2013-07 / mwalther"
  input array<String> iCompDescs;
protected
  Integer compIdx;
  String compDesc;
algorithm
  for compIdx in 1:arrayLength(iCompDescs) loop
    compDesc := arrayGet(iCompDescs,compIdx);
    print("component " + intString(compIdx) + " is described with: " + compDesc + "\n");
  end for;
  print("--------------------------------\n");
end printCompDescs;

protected function printExeCosts " prints the information about the execution costs of every component in task graph meta
author: Waurich TUD 2013-07 / mwalther"
  input array<tuple<Integer,Real>> iExeCosts;
protected
  Integer compIdx;
  Integer opCount;
  Real execTime;
algorithm
  for compIdx in 1:arrayLength(iExeCosts) loop
    (opCount,execTime) := arrayGet(iExeCosts,compIdx);
    print("component " + intString(compIdx) + " has execution cost of: (" + intString(opCount) + "," + realString(execTime) + ")\n");
  end for;
  print("--------------------------------\n");
end printExeCosts;

protected function printCommCosts " prints the information about the the communication costs of every edge.
author:Waurich TUD 2013-06 / mwalther"
  input array<Communications> iCommCosts;
protected
  Integer nodeIdx;
  Communications nodeComms;
algorithm
  for nodeIdx in 1:arrayLength(iCommCosts) loop
    nodeComms := arrayGet(iCommCosts,nodeIdx);
    print("edges from node " + intString(nodeIdx) + ": with the communication costs " + stringDelimitList(List.map(nodeComms,printCommCost), ", ") + "\n");
  end for;
  print("--------------------------------\n");
end printCommCosts;

public function printCommCost "author:marcusw
Prints the information about the the communication costs of one edge."
  input Communication iComm;
  output String oCommString;
protected
  Integer numberOfVars,numberOfIntegers,numberOfFloats,numberOfBooleans,childNode;
  list<Integer> integerVars,floatVars,booleanVars;
  Real requiredTime;
algorithm
  COMMUNICATION(numberOfVars=numberOfVars,integerVars=integerVars,floatVars=floatVars,booleanVars=booleanVars,childNode=childNode,requiredTime=requiredTime) := iComm;
  numberOfIntegers := listLength(integerVars);
  numberOfFloats := listLength(floatVars);
  numberOfBooleans := listLength(booleanVars);
  oCommString := "(target node: " + intString(childNode) + " ints: " + intString(numberOfIntegers) + " floats: " + intString(numberOfFloats) + " booleans: " + intString(numberOfBooleans) + " [requiredTime: " + realString(requiredTime) + " for " + intString(numberOfVars) + " variables)";
end printCommCost;

public function printNodeMarks " prints the information about additional NodeMark
author: Waurich TUD 2013-07 / mwalther"
  input array<Integer> iNodeMarks;
protected
  Integer compIdx, mark;
algorithm
  for compIdx in 1:arrayLength(iNodeMarks) loop
    mark := arrayGet(iNodeMarks,compIdx);
    print("component " + intString(compIdx) + " has the nodeMark : " + intString(mark) + "\n");
  end for;
  print("--------------------------------\n");
end printNodeMarks;

public function printComponentInformations "function to print the component informations of task graph meta
  author:mwalther"
  input array<ComponentInfo> iComponentInformations;
protected
  Integer compIdx;
  Boolean isPartOfODESystem;
  Boolean isPartOfEventSystem;
  Boolean isRemovedComponent;
algorithm
  for compIdx in 1:arrayLength(iComponentInformations) loop
    COMPONENTINFO(isPartOfODESystem=isPartOfODESystem,isPartOfEventSystem=isPartOfEventSystem,isRemovedComponent=isRemovedComponent) := arrayGet(iComponentInformations, compIdx);
    print("component " + intString(compIdx) + " has component information:\n");
    print("   Is part of ODE-System:   " + boolString(isPartOfODESystem) + "\n");
    print("   Is part of Event-System: " + boolString(isPartOfEventSystem) + "\n");
    print("   Is removed component:    " + boolString(isRemovedComponent) + "\n");
  end for;
  print("--------------------------------\n");
end printComponentInformations;

public function intLstString "function to print a list<Integer>
author:Waurich TUD 2013-07"
  input list<Integer> lstIn;
  output String strOut;
protected
  String str;
algorithm
  str := stringDelimitList(List.map(lstIn,intString),",");
  strOut := if List.isEmpty(lstIn) then "---" else str;
end intLstString;

public function dumpCriticalPathInfo "author:marcusw
  dump the criticalPath and the costs to a string."
  input tuple<list<list<Integer>>,Real> iCriticalPaths; //<%criticalPath, criticalPathOpCost%>
  input tuple<list<list<Integer>>,Real> iCriticalPathsWoC; //<%criticalPath, criticalPathOpCost%>
  output String oString;
protected
  String tmpString;
  list<list<Integer>> critPath, critPathWoC;
  Real costPath, costPathWoC;
algorithm
  oString := matchcontinue(iCriticalPaths,iCriticalPathsWoC)
  case(({},_),_)
    equation
    then
      "";
  case((critPath,costPath),(critPathWoC,costPathWoC))
    equation
      tmpString = "critical path with costs of "+realString(costPath)+" cycles -- ";
      tmpString = tmpString + dumpCriticalPathInfo1(critPath,1);
      tmpString = " ;; " + tmpString + "critical path' with costs of "+realString(costPathWoC)+" cycles -- ";
      tmpString = tmpString + dumpCriticalPathInfo1(critPathWoC,1);
  then
    tmpString;
  end matchcontinue;
end dumpCriticalPathInfo;

protected function dumpCriticalPathInfo1 "author:marcusw
  Helper function of dumpCriticalPathInfo. Dump one critical path."
  input list<list<Integer>> criticalPathsIn;
  input Integer cpIdx;
  output String oString;
algorithm
  oString := intLstString(listGet(criticalPathsIn,cpIdx))+"";
end dumpCriticalPathInfo1;

public function printCriticalPathInfo "prints the criticalPath and the costs.
author:Waurich TUD 2013-07"
  input list<list<Integer>> criticalPathsIn;
  input Real cpCosts;
algorithm
  _ := matchcontinue(criticalPathsIn,cpCosts)
  case({},_)
    equation
    then
      ();
  else
    equation
    print("--------------------------------\n");
    print(" CRITICAL PATH INFO\n");
    print("--------------------------------\n");
    print("found "+intString(listLength(criticalPathsIn))+" critical paths with costs of "+realString(cpCosts)+" sec\n");
    printCriticalPathInfo1(criticalPathsIn,1);
  then
    ();
  end matchcontinue;
end printCriticalPathInfo;


protected function printCriticalPathInfo1"prints one criticalPath.
author: Waurich TUD 2013-07"
  input list<list<Integer>> criticalPathsIn;
  input Integer cpIdx;
algorithm
  print(intString(cpIdx)+". path: "+intLstString(listGet(criticalPathsIn,cpIdx))+"\n");
end printCriticalPathInfo1;


//--------------------------
//  Functions to merge nodes
//--------------------------

public function mergeSingleNodes"merges all single nodes. the max number of remaining single ndoes is numProc."
  input TaskGraph iTaskGraph;
  input TaskGraphMeta iTaskGraphMeta;
  input list<Integer> doNotMergeIn;
  output TaskGraph oTaskGraph;
  output TaskGraphMeta oTaskGraphMeta;
  output Boolean changed;
algorithm
  (oTaskGraph,oTaskGraphMeta,changed) := matchcontinue(iTaskGraph,iTaskGraphMeta,doNotMergeIn)
    local
      Integer numProc;
      list<Integer> singleNodes,singleNodes1,pos,doNotMerge;
      list<list<Integer>> clusterLst;
      list<Real> exeCosts;
      array<Real> costs;
      array<list<Integer>> cluster;
      TaskGraph taskGraphT;
    case(_,_,_)
      equation
        numProc = Flags.getConfigInt(Flags.NUM_PROC);
        taskGraphT = BackendDAEUtil.transposeMatrix(iTaskGraph,arrayLength(iTaskGraph));
        //get the single nodes, sort them according to their exeCosts in decreasing order
        (_,singleNodes) = List.filterOnTrueSync(arrayList(iTaskGraph),List.isEmpty,List.intRange(arrayLength(iTaskGraph)));  //nodes without successor
        (_,singleNodes1) = List.filterOnTrueSync(arrayList(taskGraphT),List.isEmpty,List.intRange(arrayLength(taskGraphT))); //nodes without predecessor
        (singleNodes,_,_) = List.intersection1OnTrue(singleNodes,singleNodes1,intEq);
        (_,singleNodes,_) = List.intersection1OnTrue(singleNodes,doNotMergeIn,intEq);
        exeCosts = List.map1(singleNodes,getExeCostReqCycles,iTaskGraphMeta);
        (exeCosts,pos) = HpcOmScheduler.quicksortWithOrder(exeCosts);
        singleNodes = List.map1(pos,List.getIndexFirst,singleNodes);
        singleNodes = listReverse(singleNodes);
        //print("singleNodes "+stringDelimitList(List.map(singleNodes,intString),"\n")+"\n");
        exeCosts = listReverse(exeCosts);
        // cluster these singleNodes
        (cluster,_) = distributeToClusters(singleNodes,exeCosts,numProc);
        //print("cluster "+stringDelimitList(List.map(arrayList(cluster),intLstString),"\n")+"\n");
        //update taskgraph and taskgraphMeta
        _ = arrayList(cluster);
        //(oTaskGraph,oTaskGraphMeta) = contractNodesInGraph(clusterLst,iTaskGraph,iTaskGraphMeta);
        changed = intGt(listLength(singleNodes),numProc);
  then (iTaskGraph,iTaskGraphMeta,changed);
  else (iTaskGraph,iTaskGraphMeta,false);
  end matchcontinue;
end mergeSingleNodes;

public function distributeToClusters"takes a list of items and corresponding values and clusters the items. The cluster are supposed to have an most equal distribution of accumulated values.
if the items list is shorter than the numProc, a cluster list containing empty lists is output
author:Waurich TUD 2014-06"
  input list<Integer> items;
  input list<Real> values;
  input Integer numClusters;
  output array<list<Integer>> clustersOut;
  output array<Real> clusterValuesOut;
protected
  Boolean b;
  array<Integer> itemArr;
  array<list<Integer>> itemsCopy, clusters;
  array<Real> clusterValues;
algorithm
  b := intGt(listLength(items),numClusters);
  clusters := listArray(List.map(List.intRange(listLength(items)),List.create));
  clusterValues := listArray(values);
  itemArr := listArray(items);
  itemsCopy := Array.map(itemArr,List.create);
  clusters := if true then Array.copy(itemsCopy,clusters) else clusters;
  clusterValues := if not b then Array.copy(listArray(values),clusterValues) else clusterValues;
  if b then
    (clustersOut,clusterValuesOut) := distributeToClusters1((items,values),(clusters,clusterValues),numClusters);
  else
    (clustersOut,clusterValuesOut) := (clusters,clusterValues);
  end if;
end distributeToClusters;

protected function distributeToClusters1
  input tuple<list<Integer>,list<Real>> tplIn;  //<items,values>
  input tuple<array<list<Integer>>,array<Real>> tplFold;  // <<a item mapping :item-> included items>, <item: added costs of all included items>>
  input Integer numClusters;
  output array<list<Integer>> clustersOut;
  output array<Real> clusterValuesOut;
algorithm
  (clustersOut,clusterValuesOut) := matchcontinue(tplIn,tplFold,numClusters)
    local
      Integer numCl, diff;
      list<Integer> itemsIn,lst1,lst1_1,lst1_2,idcsLst1_2,idcsLst2,idcsLst1;
      list<list<Integer>> entries,entries2;
      list<Real> valuesIn,values,addValues;
      array<list<Integer>> clusters, clustersFinal;
      array<Real> clusterValues, clusterValuesFinal;
  case((itemsIn,_),(clusters,clusterValues),_)
    equation
      true = listLength(itemsIn) <= numClusters;
      idcsLst1 = List.intRange(numClusters);
      clustersFinal = Array.select(clusters,idcsLst1);
      clusterValuesFinal = Array.select(clusterValues,idcsLst1);
    then (clustersFinal,clusterValuesFinal);
  case((itemsIn,valuesIn),(clusters,clusterValues),_)
    equation
      true = listLength(itemsIn) > numClusters;
      true = listLength(itemsIn)/2 < numClusters;
      (lst1,_) = List.split(itemsIn,numClusters);  // split the list of items+dummies in the middle
      diff = listLength(itemsIn) - numClusters;
      idcsLst1 = List.intRange2(numClusters-diff+1,numClusters);
      idcsLst2 = List.intRange2(numClusters+1,listLength(itemsIn));
      // update the clusters array
      entries = List.map1(idcsLst2,Array.getIndexFirst,clusters);
      entries = listReverse(entries);
      entries2 = List.map1(idcsLst1,Array.getIndexFirst,clusters);
      entries = List.threadMap(entries,entries2,listAppend);
      List.threadMap1_0(idcsLst1,entries,Array.updateIndexFirst,clusters);
      // update the clusterValues array
      values = List.map1(idcsLst1,Array.getIndexFirst,clusterValues);
      addValues = List.map1(idcsLst2,Array.getIndexFirst,clusterValues);
      values = List.threadMap(values,addValues,realAdd);
      List.threadMap1_0(idcsLst1,values,Array.updateIndexFirst,clusterValues);
      // finish
      (clusters,clusterValues) = distributeToClusters1((lst1,valuesIn),(clusters,clusterValues),numClusters);
    then (clusters,clusterValues);
  case((itemsIn,valuesIn),(clusters,clusterValues),_)
    equation
      true = listLength(itemsIn) > numClusters;
      true = listLength(itemsIn)/2 >= numClusters;
      numCl = nextGreaterPowerOf2(intReal(listLength(itemsIn)));
      (lst1,_) = List.split(itemsIn,intDiv(numCl,2));  // split the list of items+dummies in the middle
      // update the clusters array
      idcsLst2 = List.intRange2(intDiv(numCl,2)+1,listLength(itemsIn));
      idcsLst1_2 = List.intRange2(intDiv(numCl,2)-listLength(idcsLst2)+1, intDiv(numCl,2));
      entries = List.map1(idcsLst2,Array.getIndexFirst,clusters);  // the clustered task from  the second list
      entries = listReverse(entries);
      entries2 = List.map1(idcsLst1_2,Array.getIndexFirst,clusters);
      entries = List.threadMap(entries,entries2,listAppend);
      List.threadMap1_0(idcsLst1_2,entries,Array.updateIndexFirst,clusters);
      // update the clusterValues array
      values = List.map1(idcsLst1_2,Array.getIndexFirst,clusterValues);
      addValues = List.map1(idcsLst2,Array.getIndexFirst,clusterValues);
      values = List.threadMap(values,addValues,realAdd);
      List.threadMap1_0(idcsLst1_2,values,Array.updateIndexFirst,clusterValues);
      // again
      (clusters,clusterValues) = distributeToClusters1((lst1,valuesIn),(clusters,clusterValues),numClusters);
    then (clusters,clusterValues);
  else
    equation
      print("distributeToClusters failed!\n");
    then fail();
  end matchcontinue;
end distributeToClusters1;

protected function nextGreaterPowerOf2"finds the next greater power of 2.
author :Waurich TUD 2014-06"
  input Real n;
  output Integer powOf2;
algorithm
  powOf2 := nextGreaterPowerOf2_impl(n,1);
end nextGreaterPowerOf2;

protected function nextGreaterPowerOf2_impl
  input Real n;
  input Integer pow;
  output Integer powOf2;
algorithm
  powOf2 := matchcontinue(n,pow)
  local
    Integer n2;
  case(_,_)
    equation
      true = n <=. realPow(2.0,intReal(pow));
    then realInt(realPow(2.0,intReal(pow)));
  case(_,_)
    equation
      true = n >. realPow(2.0,intReal(pow));
      n2 = nextGreaterPowerOf2_impl(n,pow+1);
    then n2;
  end matchcontinue;
end nextGreaterPowerOf2_impl;

public function mergeSimpleNodes " merges all nodes in the graph that have only one predecessor and one successor.
author: Waurich TUD 2013-07"
  input TaskGraph graphIn;
  input TaskGraph graphTIn;
  input TaskGraphMeta graphDataIn;
  input array<Integer> contractedTasksIn;
  output TaskGraph graphOut; //TaskGraph-Edges are updated on the fly
  output TaskGraph graphTOut;
  output TaskGraphMeta graphDataOut;
  output array<Integer> contractedTasksOut; //removed task has value -1; not touched task has value 0
  output Boolean changed;
protected
  list<Integer> allNodes, child;
  list<list<Integer>> oneChildren;
algorithm
  allNodes := List.intRange(arrayLength(graphIn));  // to traverse the node indeces
  oneChildren := findOneChildParents(allNodes,graphIn,{},{{}},0,contractedTasksIn);  // paths of nodes with just one successor per node (extended: and endnodes with just one parent node)
  //for child in oneChildren loop
  //  print("oneChildren " + stringDelimitList(List.map(child, intString), ",") + "\n");
  //end for;
  oneChildren := listDelete(oneChildren,listLength(oneChildren)); // remove the empty startValue {}
  oneChildren := List.removeOnTrue(1,compareListLengthOnTrue,oneChildren);  // remove paths of length 1
  //print("oneChildren "+stringDelimitList(List.map(oneChildren,intLstString),"\n")+"\n");
  //(graphOut,graphTOut,graphDataOut,contractedTasksOut) := contractNodesInGraph(oneChildren,graphIn,graphTIn,graphDataIn,contractedTasksIn);
  (graphOut,graphTOut,graphDataOut,contractedTasksOut) := contractNodesInGraph(oneChildren,graphIn,graphTIn,graphDataIn,contractedTasksIn);
  changed := List.isNotEmpty(oneChildren);
  //print("contractedTasksOut "+stringDelimitList(List.map(arrayList(contractedTasksOut),intString),"\n")+"\n");
end mergeSimpleNodes;

public function mergeParentNodes "author: marcusw,waurich
  Merges parent nodes into child if this produces a shorter execution time."
  input TaskGraph graphIn;
  input TaskGraph graphTIn;
  input TaskGraphMeta graphDataIn;
  input array<Integer> contractedTasksIn;
  output TaskGraph graphOut;
  output TaskGraph graphTOut;
  output TaskGraphMeta graphDataOut;
  output array<Integer> contractedTasksOut;
  output Boolean changed;
protected
  array<Integer> alreadyMerged;
  list<list<Integer>> mergedNodes;
algorithm
  alreadyMerged := arrayCreate(arrayLength(graphIn),0);
  mergedNodes := mergeParentNodes0(graphIn, graphTIn, graphDataIn, contractedTasksIn, alreadyMerged, 1, {});
  //print("mergedNodes "+stringDelimitList(List.map(mergedNodes,intLstString),"\n")+"\n");
  (graphOut,graphTOut,graphDataOut,contractedTasksOut) := contractNodesInGraph(mergedNodes,graphIn,graphTIn,graphDataIn,contractedTasksIn);
  changed := List.isNotEmpty(mergedNodes);
  //print("contractedTasksOut "+stringDelimitList(List.map(arrayList(contractedTasksOut),intString),"\n")+"\n");
end mergeParentNodes;

protected function mergeParentNodes0
  input TaskGraph iGraph;
  input TaskGraph iGraphT;
  input TaskGraphMeta iGraphData;
  input array<Integer> contractedTasksIn;
  input array<Integer> alreadyMerged;
  input Integer iNodeIdx;
  input list<list<Integer>> iMergedNodes;
  output list<list<Integer>> oMergedNodes;
protected
  TaskGraph tmpGraph;
  TaskGraphMeta tmpGraphData;
  Boolean tmpChanged;
  Real highestParentExeCost, sumParentExeCosts;
  list<Integer> parentNodes, mergeNodeList;
  Real highestCommCost;
  array<tuple<Integer, Real>> exeCosts;
  list<tuple<Integer, Real>> parentExeCosts;
  array<Communications> commCosts;
  Communications parentCommCosts;
  list<list<Integer>> parentChilds;
  list<list<Integer>> tmpMergedNodes;
algorithm
  oMergedNodes := matchcontinue(iGraph, iGraphT, iGraphData, contractedTasksIn, alreadyMerged,  iNodeIdx, iMergedNodes)
    case(_,_,TASKGRAPHMETA(exeCosts=exeCosts, commCosts=commCosts),_,_,_,_)
      equation
        true = intLe(iNodeIdx, arrayLength(iGraphT)); //Current index is in range
        true = intNe(arrayGet(contractedTasksIn,iNodeIdx),-1);
        true = intNe(arrayGet(alreadyMerged,iNodeIdx),-1);  // is not already in a merged task group
        //print("HpcOmTaskGraph.mergeParentNodes0: looking at node " + intString(iNodeIdx) + "\n");
        parentNodes = arrayGet(iGraphT, iNodeIdx);
        parentNodes = filterContractedNodes(parentNodes,contractedTasksIn);
        false = List.exist1(parentNodes,isNodeContracted,alreadyMerged);// dont consider nodes that are already merged in this iteration
        //print("with the parents "+stringDelimitList(List.map(parentNodes,intString),", ")+"\n");
        parentCommCosts = List.map2(parentNodes, getCommCostBetweenNodes, iNodeIdx, iGraphData);
        COMMUNICATION(requiredTime=highestCommCost) = getHighestCommCost(parentCommCosts, COMMUNICATION(0,{},{},{},{},-1,-1.0));
        parentExeCosts = List.map1(parentNodes, getExeCost, iGraphData);
        ((_,sumParentExeCosts)) = List.fold(parentExeCosts, addUpExeCosts, (0,0.0));
        ((_,highestParentExeCost)) = getHighestExecCost(parentExeCosts, (0,0.0));
        true = realGt(realAdd(highestCommCost, highestParentExeCost), sumParentExeCosts);
        //We can only merge the parents if they have no other child-nodes -> check this
        parentChilds = List.map1(parentNodes, Array.getIndexFirst, iGraph);
        true = intEq(listLength(List.removeOnTrue(1, intEq, List.map(parentChilds, listLength))), 0);
        mergeNodeList = iNodeIdx :: parentNodes;
        //print("HpcOmTaskGraph.mergeParentNodes0: mergeNodeList " + stringDelimitList(List.map(mergeNodeList,intString), ", ") + "\n");
        //print("HpcOmTaskGraph.mergeParentNodes0: Merging " + intString(iNodeIdx) + " with " + stringDelimitList(List.map(parentNodes,intString), ", ") + "\n");
        tmpMergedNodes = mergeNodeList :: iMergedNodes;
        List.map_0(mergeNodeList,function Array.updateIndexFirst(inValue=-1,inArray=alreadyMerged));
        tmpMergedNodes = mergeParentNodes0(iGraph,iGraphT,iGraphData,contractedTasksIn,alreadyMerged,iNodeIdx+1,tmpMergedNodes);
      then tmpMergedNodes;
    case(_,_,_,_,_,_,_)
      equation
        true = intLe(iNodeIdx, arrayLength(iGraphT)); //Current index is in range
        tmpMergedNodes = mergeParentNodes0(iGraph,iGraphT,iGraphData,contractedTasksIn,alreadyMerged,iNodeIdx+1,iMergedNodes);
      then tmpMergedNodes;
    else iMergedNodes;
  end matchcontinue;
end mergeParentNodes0;

public function markSystemComponents "author: marcusw
  Mark all components that are part of the given Task Graph in the target task graph meta with (ComponentInfo OR iComponentInfo)"
  input TaskGraph iTaskGraph;
  input TaskGraphMeta iTaskGraphMeta;
  input tuple<Boolean, Boolean, Boolean> iComponentMarks; //<isPartOfODESystem, isPartOfEventSystem, isRemovedComponent>
  input TaskGraphMeta iTargetTaskGraphMeta;
  output TaskGraphMeta oTargetTaskGraphMeta;
protected
  array<list<Integer>> odeInComps;
  list<Integer> nodeComps;
  Integer nodeIdx, compIdx;

  array<list<Integer>> inComps;
  array<tuple<Integer,Integer,Integer>> varCompMapping;
  array<tuple<Integer,Integer,Integer>> eqCompMapping;
  array<list<Integer>> compParamMapping;
  array<String> compNames;
  array<String> compDescs;
  array<tuple<Integer,Real>> exeCosts;
  array<Communications> commCosts;
  array<Integer> nodeMark;
  array<ComponentInfo> compInformations;
  ComponentInfo componentInformation, iComponentInformation;
algorithm
  iComponentInformation := COMPONENTINFO(Util.tuple31(iComponentMarks), Util.tuple32(iComponentMarks), Util.tuple33(iComponentMarks));
  TASKGRAPHMETA(inComps=odeInComps) := iTaskGraphMeta;
  TASKGRAPHMETA(inComps,varCompMapping,eqCompMapping,compParamMapping,compNames,compDescs,exeCosts,commCosts,nodeMark,compInformations) := iTargetTaskGraphMeta;
  for nodeIdx in 1:arrayLength(iTaskGraph) loop
    nodeComps := arrayGet(odeInComps, nodeIdx);
    for compIdx in nodeComps loop
      componentInformation := combineComponentInformations(arrayGet(compInformations, compIdx), iComponentInformation);
      compInformations := arrayUpdate(compInformations, compIdx, componentInformation);
    end for;
  end for;
  oTargetTaskGraphMeta := TASKGRAPHMETA(inComps,varCompMapping,eqCompMapping,compParamMapping,compNames,compDescs,exeCosts,commCosts,nodeMark,compInformations);
end markSystemComponents;

protected function combineComponentInformations "author: marcusw
  Return all boolean values of iComponentInfo OR iComponentInfo2"
  input ComponentInfo iComponentInfo;
  input ComponentInfo iComponentInfo2;
  output ComponentInfo oComponentInfo;
protected
  Boolean isPartOfODESystem, iIsPartOfODESystem;
  Boolean isPartOfEventSystem, iIsPartOfEventSystem;
  Boolean isRemovedComponent, iIsRemovedComponent;
algorithm
  COMPONENTINFO(isPartOfODESystem, isPartOfEventSystem, isRemovedComponent) := iComponentInfo;
  COMPONENTINFO(iIsPartOfODESystem, iIsPartOfEventSystem, iIsRemovedComponent) := iComponentInfo2;
  oComponentInfo := COMPONENTINFO(boolOr(isPartOfODESystem, iIsPartOfODESystem), boolOr(isPartOfEventSystem, iIsPartOfEventSystem), boolOr(isRemovedComponent, iIsRemovedComponent));
end combineComponentInformations;

protected function addUpExeCosts
  input tuple<Integer,Real> iExeCost1;
  input tuple<Integer,Real> iExeCost2;
  output tuple<Integer,Real> oExeCost;
protected
  Real ex1,ex2;
  Integer op1,op2;
algorithm
  (op1,ex1) := iExeCost1;
  (op2,ex2) := iExeCost2;
  oExeCost := ((op1+op2,realAdd(ex1,ex2)));
end addUpExeCosts;

public function getExeCostReqCycles"author: waurich
  gets the execution cost of the node in cycles."
  input Integer iNodeIdx;
  input TaskGraphMeta iGraphData;
  output Real oExeCost;
protected
  array<list<Integer>> inComps;
  list<Integer> comps;
  array<tuple<Integer, Real>> exeCosts;
  tuple<Integer,Real> tmpExeCost;
algorithm
  TASKGRAPHMETA(inComps=inComps, exeCosts=exeCosts) := iGraphData;
  tmpExeCost := (0,0.0);
  comps := arrayGet(inComps, iNodeIdx);
  ((_,oExeCost)) := List.fold1(comps, getExeCost0, exeCosts, tmpExeCost);
end getExeCostReqCycles;

public function getExeCost "author: marcusw
  gets the execution cost of the node."
  input Integer iNodeIdx;
  input TaskGraphMeta iGraphData;
  output tuple<Integer,Real> oExeCost;
protected
  array<list<Integer>> inComps;
  list<Integer> comps;
  array<tuple<Integer, Real>> exeCosts;
  tuple<Integer,Real> tmpExeCost;
algorithm
  TASKGRAPHMETA(inComps=inComps, exeCosts=exeCosts) := iGraphData;
  tmpExeCost := (0,0.0);
  comps := arrayGet(inComps, iNodeIdx);
  oExeCost := List.fold1(comps, getExeCost0, exeCosts, tmpExeCost);
end getExeCost;

protected function getExeCost0 "author: marcusw
  Helper function of getExeCost."
  input Integer iCompIdx;
  input array<tuple<Integer, Real>> iExeCosts;
  input tuple<Integer,Real> iExeCost;
  output tuple<Integer,Real> oExeCost;
protected
  Real exeCost, exeCost1;
  Integer opCount, opCount1;
algorithm
  ((opCount,exeCost)) := arrayGet(iExeCosts, iCompIdx);
  (opCount1,exeCost1) := iExeCost;
  oExeCost := ((opCount+opCount1,realAdd(exeCost,exeCost1)));
end getExeCost0;

protected function getHighestExecCost "function getHighestExecCost
  author: marcusw
  Get the communication with highest costs out of the given list."
  input list<tuple<Integer, Real>> iExecCosts;
  input tuple<Integer, Real> iHighestTuple;
  output tuple<Integer, Real> oHighestTuple;
protected
  Real highestCost, currentCost;
  tuple<Integer, Real> head;
  list<tuple<Integer, Real>> rest;
algorithm
  oHighestTuple := matchcontinue(iExecCosts, iHighestTuple)
    case((head as (_,currentCost))::rest, (_,highestCost))
      equation
        true = realGt(currentCost, highestCost);
      then getHighestExecCost(rest, head);
    case((head as (_,currentCost))::rest, (_,highestCost))
      equation
        true = realGt(currentCost, highestCost);
      then getHighestExecCost(rest, iHighestTuple);
    else iHighestTuple;
  end matchcontinue;
end getHighestExecCost;

public function contractNodesInGraph "contract the nodes given in the list to one node. Take care that the lists are disjoint.
author: marcusw"
  input list<list<Integer>> iContractNodes; //a list containing a list with nodes you want to merge
  input TaskGraph iTaskGraph;
  input TaskGraph iTaskGraphT;
  input TaskGraphMeta iTaskGraphMeta;
  input array<Integer> iContractedTasks;
  output TaskGraph oTaskGraph;
  output TaskGraph oTaskGraphT;
  output TaskGraphMeta oTaskGraphMeta;
  output array<Integer> oContractedTasks;
 protected
  //TaskGraph Meta
  array<list<Integer>> inComps;

  TaskGraph tmpTaskGraph = iTaskGraph;
  TaskGraph tmpTaskGraphT = iTaskGraphT;
  array<Integer> tmpContractedTasks = iContractedTasks;
  Integer nodeListHeadIdx, negNodeListHeadIdx, nodeIdx, nodeContractionValue, parentChild, parentChildContractionValue;
  list<Integer> nodeListRestIdc, nodeCompIdc, headCompIdc;
  list<Integer> parentNodeChildList, parentNodeChildListNew; //all children of a parent node
  list<Integer> outgoingEdges, incomingEdges; //edges from 'nodeListHeadIdx' to all nodes that are not part of the merging cluster
  array<Integer> nodeMarks;
  array<Integer> nodeMarksT;
  list<Integer> iNodeList, nodeList;
  list<Integer> childNodes; //all nodes that are at least "below" one node of the node list
  list<Integer> parentNodes; //all nodes that have at least one node of the merged cluster as children
algorithm
  TASKGRAPHMETA(inComps=inComps) := iTaskGraphMeta;

  nodeMarks := arrayCreate(arrayLength(iTaskGraph), 0);
  nodeMarksT := arrayCreate(arrayLength(iTaskGraph), 0);

  //print("contractNodesInGraph: Merging " + intString(listLength(iContractNodes)) + " groups of nodes at once\n");
  for iNodeList in iContractNodes loop
    //print("contractNodesInGraph: Merging nodes in " + stringDelimitList(List.map(iNodeList,intString),",") + "\n");
    //print("Task Graph:");
    //printTaskGraph(tmpTaskGraph);
    //print("Transposed Task Graph:");
    //printTaskGraph(tmpTaskGraphT);
    nodeList := {};
    nodeListHeadIdx::nodeListRestIdc := iNodeList; //O(1)
    for nodeIdx in iNodeList loop
      nodeIdx := getRealTaskIdxOfTask(nodeIdx, tmpContractedTasks); //O(1)
      //Detect already merged groups
      if(intNe(arrayGet(nodeMarks, nodeIdx), nodeListHeadIdx)) then
        nodeMarks := arrayUpdate(nodeMarks, nodeIdx, nodeListHeadIdx);
        nodeList := nodeIdx::nodeList;
      end if;
    end for;

    //print("contractNodesInGraph: Merging nodes " + stringDelimitList(List.map(nodeList,intString),",") + "\n");

    //Get the index of the merged node
    nodeListHeadIdx::nodeListRestIdc := nodeList; //O(1)
    nodeListHeadIdx := getRealTaskIdxOfTask(nodeListHeadIdx, tmpContractedTasks);

    negNodeListHeadIdx := intMul(-1, nodeListHeadIdx);

    //Set the nodeMark-value of all 'nodeListRestIdc' to nodeListHeadIdx and set the contracted value O(n)
    for nodeIdx in nodeListRestIdc loop
      nodeMarks := arrayUpdate(nodeMarks, nodeIdx, nodeListHeadIdx);
      nodeMarksT := arrayUpdate(nodeMarksT, nodeIdx, nodeListHeadIdx);
      tmpContractedTasks := arrayUpdate(tmpContractedTasks, nodeIdx, negNodeListHeadIdx);
    end for;

    //Set the mark of all nodeList-nodes to 'nodeListHeadIdx'
    nodeMarks := arrayUpdate(nodeMarks, nodeListHeadIdx, nodeListHeadIdx);
    nodeMarksT := arrayUpdate(nodeMarksT, nodeListHeadIdx, nodeListHeadIdx);
    //print("contractNodesInGraph: Node marks " + stringDelimitList(arrayList(Array.map(nodeMarks,intString)),",") + "\n");
    //print("contractNodesInGraph: Contracted nodes " + stringDelimitList(arrayList(Array.map(tmpContractedTasks,intString)),",") + "\n");

    //Set the mark of all nodes connected with 'nodeListHeadIdx' to 'nodeListHeadIdx'
    outgoingEdges := arrayGet(tmpTaskGraph, nodeListHeadIdx);
    outgoingEdges := List.deleteMemberOnTrue(negNodeListHeadIdx,outgoingEdges,function checkIfNodeBelongsToCluster(iContractedTasks=tmpContractedTasks)); //O(n)

    incomingEdges := arrayGet(tmpTaskGraphT, nodeListHeadIdx);

    List.map_0(outgoingEdges, function Array.updateIndexFirst(inValue=nodeListHeadIdx, inArray=nodeMarks)); //O(n)
    List.map_0(incomingEdges, function Array.updateIndexFirst(inValue=nodeListHeadIdx, inArray=nodeMarksT)); //O(n)

    //print("contractNodesInGraph: Node marks " + stringDelimitList(arrayList(Array.map(nodeMarks,intString)),",") + "\n");

    //Get all child-nodes (parent-nodes) of the nodes in the node-list and remove the nodes that are part of the node-list itself or connected to 'nodeListHeadIdx'
    childNodes := List.flatten(List.map(nodeListRestIdc,function getContractedNodeChildren(iRefValue=nodeListHeadIdx,iTaskGraph=tmpTaskGraph,iContractedTasks=tmpContractedTasks,iNodeMarks=nodeMarks))); //O(e)
    parentNodes := List.flatten(List.map(nodeList,function getContractedNodeChildren(iRefValue=nodeListHeadIdx,iTaskGraph=iTaskGraphT,iContractedTasks=tmpContractedTasks,iNodeMarks=nodeMarks))); //O(e)

    //print("contractNodesInGraph: Child nodes " + stringDelimitList(List.map(childNodes,intString),",") + "\n");
    //print("contractNodesInGraph: Parent nodes " + stringDelimitList(List.map(parentNodes,intString),",") + "\n");

    headCompIdc := arrayGet(inComps, nodeListHeadIdx);
    //Delete all outgoing edges of 'nodeListRestIdc' O(n)
    for nodeIdx in nodeListRestIdc loop
      tmpTaskGraph := arrayUpdate(tmpTaskGraph, nodeIdx, {});
      tmpTaskGraphT := arrayUpdate(tmpTaskGraphT, nodeIdx, {});
      nodeCompIdc := arrayGet(inComps, nodeIdx);
      inComps := arrayUpdate(inComps, nodeIdx, {});
      headCompIdc := List.insertListSorted(headCompIdc, nodeCompIdc, intLt);
    end for;

    //print("contractNodesInGraph: Components for head-node '" + intString(nodeListHeadIdx) + "' are '{" + stringDelimitList(List.map(headCompIdc, intString), ",") + "}'\n");
    arrayUpdate(inComps, nodeListHeadIdx, headCompIdc);

    // Update transposed Task Graph
    //  Handle all parent nodes first
    for nodeIdx in parentNodes loop
      if(intNe(arrayGet(nodeMarksT, nodeIdx), nodeListHeadIdx)) then
        incomingEdges := nodeIdx::incomingEdges;
      end if;
    end for;
    //print("contractNodesInGraph: Set incomming edges to '" + stringDelimitList(List.map(incomingEdges, intString), ",") + "'\n");
    tmpTaskGraphT := arrayUpdate(tmpTaskGraphT, nodeListHeadIdx, incomingEdges);

    for nodeIdx in childNodes loop
      parentNodeChildList := arrayGet(tmpTaskGraphT, nodeIdx);
      //print("contractNodesInGraph: Handle parents of node '" + intString(nodeIdx) + "' = '{" + stringDelimitList(List.map(parentNodeChildList, intString), ",") + "}'\n");
      //remove all child nodes that are marked with a node mark == 'nodeListHeadidx'
      parentNodeChildListNew := {};
      for parentChild in parentNodeChildList loop
        parentChildContractionValue := arrayGet(tmpContractedTasks, parentChild);
        parentChild := getRealTaskIdxOfTask(parentChild, tmpContractedTasks);

        //print("contractNodesInGraph: Children '" + intString(parentChild) + "' has mark '" + intString(arrayGet(nodeMarksT, parentChild)) + "'\n");
        if(intEq(parentChild, nodeListHeadIdx) or intEq(parentChildContractionValue, negNodeListHeadIdx)) then //Check if child belongs to cluster
          //print("contractNodesInGraph: Node '" + intString(nodeIdx) + "' has mark '" + intString(arrayGet(nodeMarksT, nodeIdx)) + "'\n");
          if(intNe(arrayGet(nodeMarksT, parentChild), nodeIdx)) then //Check if edge from 'nodeListHeadIdx' to 'nodeIdx' was already added
            parentNodeChildListNew := nodeListHeadIdx::parentNodeChildListNew;
            _ := arrayUpdate(nodeMarksT, parentChild, nodeIdx);
          end if;
        else
          parentNodeChildListNew := parentChild::parentNodeChildListNew;
        end if;
      end for;
      //print("contractNodesInGraph: Handle parents of node '" + intString(nodeIdx) + "' = '{" + stringDelimitList(List.map(parentNodeChildListNew, intString), ",") + "}'\n");
      tmpTaskGraphT := arrayUpdate(tmpTaskGraphT, nodeIdx, parentNodeChildListNew);
    end for;

    outgoingEdges := listAppend(outgoingEdges, childNodes);

    nodeMarks := arrayUpdate(nodeMarks, nodeListHeadIdx, 0);
    // Update Task Graph
    for nodeIdx in parentNodes loop
      parentNodeChildList := arrayGet(tmpTaskGraph, nodeIdx);
      //print("contractNodesInGraph: Handle children of node '" + intString(nodeIdx) + "' = '{" + stringDelimitList(List.map(parentNodeChildList, intString), ",") + "}'\n");
      //remove all child nodes that are marked with a node mark == 'nodeListHeadidx'
      parentNodeChildListNew := {};
      for parentChild in parentNodeChildList loop
        parentChildContractionValue := arrayGet(tmpContractedTasks, parentChild);
        parentChild := getRealTaskIdxOfTask(parentChild, tmpContractedTasks);

        //print("contractNodesInGraph: Children '" + intString(parentChild) + "' has mark '" + intString(arrayGet(nodeMarks, parentChild)) + "'\n");
        if(intEq(parentChild, nodeListHeadIdx) or intEq(parentChildContractionValue, negNodeListHeadIdx)) then //Check if child belongs to cluster
          //print("contractNodesInGraph: Node '" + intString(nodeIdx) + "' has mark '" + intString(arrayGet(nodeMarks, nodeIdx)) + "'\n");
          if(intNe(arrayGet(nodeMarks, parentChild), nodeIdx)) then //Check if edge from 'nodeListHeadIdx' to 'nodeIdx' was already added
            parentNodeChildListNew := nodeListHeadIdx::parentNodeChildListNew;
            _ := arrayUpdate(nodeMarks, parentChild, nodeIdx);
          end if;
        else
          parentNodeChildListNew := parentChild::parentNodeChildListNew;
        end if;
      end for;
      //print("contractNodesInGraph: Handle children of node '" + intString(nodeIdx) + "' = '{" + stringDelimitList(List.map(parentNodeChildListNew, intString), ",") + "}'\n");
      tmpTaskGraph := arrayUpdate(tmpTaskGraph, nodeIdx, parentNodeChildListNew);
    end for;
    //print("contractNodesInGraph: finished cluster\n");
    //print("contractNodesInGraph: Outgoing edges " + stringDelimitList(List.map(outgoingEdges,intString),",") + "\n");
    tmpTaskGraph := arrayUpdate(tmpTaskGraph, nodeListHeadIdx, outgoingEdges);
  end for;
  oTaskGraph := tmpTaskGraph;
  oTaskGraphT := tmpTaskGraphT;
  oTaskGraphMeta := iTaskGraphMeta;
  oContractedTasks := iContractedTasks;
end contractNodesInGraph;

protected function checkIfNodeBelongsToCluster "returns true if the node mark of the given iNodeIdx is equal to the reference value.
author: marcusw"
  input Integer iNegativeRefValue; //the negative reference-value to check
  input Integer iNodeIdx;
  input array<Integer> iContractedTasks;
  output Boolean oIsNodePartOfCluster;
algorithm
  //print("checkIfNodeBelongsToCluster: Checking iNodeIdx '" + intString(iNodeIdx) + "' is equal to reference value '" + intString(iRefValue) + "'\n");
  oIsNodePartOfCluster := intEq(iNegativeRefValue, arrayGet(iContractedTasks, iNodeIdx));
end checkIfNodeBelongsToCluster;

protected function getContractedNodeChildren "get the child-nodes of the given parent task. If a children has a negativ contracted mark, the real node is searched.
author: marcusw"
  input Integer iParentTask;
  input Integer iRefValue;
  input TaskGraph iTaskGraph;
  input array<Integer> iContractedTasks;
  input array<Integer> iNodeMarks;
  output list<Integer> oChildTasks;
protected
  Integer task, taskMark, contractedValue;
  list<Integer> childTasks;
  list<Integer> resultTasks = {};
algorithm
  childTasks := arrayGet(iTaskGraph, iParentTask);
  //print("getContractedNodeChildren: iParentTask '" + intString(iParentTask) + "' with children " + stringDelimitList(List.map(resultTasks, intString), ",") + "\n");
  for task in childTasks loop
    task := getRealTaskIdxOfTask(task, iContractedTasks);

    taskMark := arrayGet(iNodeMarks, task);
    if(boolAnd(intNe(taskMark, iRefValue), intNe(task, iRefValue))) then
      resultTasks:=task::resultTasks;
      _ := arrayUpdate(iNodeMarks, task, iRefValue);
    else
      //print("getContractedNodeChildren: Skipping task " + intString(task) + " with taskMark " + intString(taskMark) + " and reference value " + intString(iRefValue) + "\n");
    end if;
  end for;
  //print("getContractedNodeChildren: iParentTask '" + intString(iParentTask) + "' with children " + stringDelimitList(List.map(resultTasks, intString), ",") + "\n");
  oChildTasks := resultTasks;
end getContractedNodeChildren;

protected function getRealTaskIdxOfTask "get the real task-index of the given task. If the task has a negativ contracted mark, the real node is searched.
author: marcusw"
  input Integer iTaskIdx;
  input array<Integer> iContractedTasks;
  output Integer oTaskIdx;
protected
  Integer contractionMark;
algorithm
  contractionMark := arrayGet(iContractedTasks, iTaskIdx);
  //print("getRealTaskIdxOfTask: Task-Index='" + intString(iTaskIdx) + "' with contraction mark='" + intString(contractionMark) + "'\n");
  if(intLt(contractionMark, 0)) then
    oTaskIdx := getRealTaskIdxOfTask(intMul(contractionMark, -1), iContractedTasks);
  else
    oTaskIdx := iTaskIdx;
  end if;
end getRealTaskIdxOfTask;

public function setInCompsInMeta"replaces the inComps in the taskGraphMeta.
author:Waurich TUD 2014-11"
  input array<list<Integer>> inComps;
  input TaskGraphMeta metaIn;
  output TaskGraphMeta metaOut;
protected
  array<tuple<Integer, Integer, Integer>> varCompMapping;
  array<tuple<Integer,Integer,Integer>> eqCompMapping;
  array<String> compNames;
  array<String> compDescs;
  array<tuple<Integer,Real>> exeCosts;
  array<Communications> commCosts;
  array<list<Integer>> compParamMapping;
  array<Integer> nodeMark;
  array<ComponentInfo> compInformations;
algorithm
  TASKGRAPHMETA(varCompMapping=varCompMapping, eqCompMapping=eqCompMapping, compParamMapping=compParamMapping, compNames=compNames, compDescs=compDescs, exeCosts=exeCosts, commCosts=commCosts, nodeMark=nodeMark, compInformations=compInformations) := metaIn;
  metaOut := TASKGRAPHMETA(inComps,varCompMapping,eqCompMapping,compParamMapping,compNames,compDescs,exeCosts,commCosts,nodeMark,compInformations);
end setInCompsInMeta;

protected function updateInCompsInfo"updates the inComps for the contracted nodes.
author:Waurich TUD 2014-11"
  input Integer contrNode;
  input list<Integer> removedNodes;
  input array<list<Integer>> inComps;
protected
  list<Integer> comps, contrComps;
algorithm
  //print("contrNode "+intString(contrNode)+"\n");
  comps := arrayGet(inComps,contrNode);
  contrComps := List.flatten(List.map(removedNodes,function Array.getIndexFirst(inArray=inComps)));
  comps := List.unique(listAppend(contrComps,comps));
    //print("comps "+stringDelimitList(List.map(comps,intString),", ")+"\n");
  arrayUpdate(inComps,contrNode,comps);
end updateInCompsInfo;

public function filterContractedNodes"selects only Nodes that are not already contracted.
author:Waurich TUD 2014-11"
  input list<Integer> nodesIn;
  input array<Integer> contrNodes;
  output list<Integer> nodesOut;
algorithm
  nodesOut := List.filterOnFalse(nodesIn,function isNodeContracted(iContrNodes=contrNodes));
end filterContractedNodes;

public function filterNonContractedNodes"selects only Nodes that are already contracted.
author:Waurich TUD 2014-11"
  input list<Integer> nodesIn;
  input array<Integer> contrNodes;
  output list<Integer> nodesOut;
algorithm
  nodesOut := List.filterOnTrue(nodesIn,function isNodeContracted(iContrNodes=contrNodes));
end filterNonContractedNodes;

public function isNodeContracted "ouputs true if the given node is already contracted"
  input Integer iNode;
  input array<Integer> iContrNodes;
  output Boolean oIsContracted;
algorithm
  if intLe(iNode,arrayLength(iContrNodes)) then
      oIsContracted := intLt(arrayGet(iContrNodes,iNode),0);
  else oIsContracted := false;
  end if;
end isNodeContracted;

protected function contractNodesInGraph1 " function to contract the nodes given in the list to one node, without deleting the rows in the adjacencyLst.
author: Waurich TUD 2013-07"
  input list<Integer> contractNodes;
  input TaskGraph graphIn;
  output TaskGraph graphOut;
protected
  TaskGraph graphInT;
  Integer endNode;
  Integer startNode;
  list<Integer> deleteEntries;
  list<Integer> startNodeChildren;
  list<Integer> endChildren;
  list<Integer> deleteNodesParents; //all parents of deleted nodes
  TaskGraph graphTmp;
algorithm
  //This function contracts all nodes into the startNode
  graphInT := BackendDAEUtil.transposeMatrix(graphIn,arrayLength(graphIn));
  //print("HpcOmTaskGraph.contractNodesInGraph1 contractNodes: " + stringDelimitList(List.map(contractNodes,intString),",") + "\n");
  //print("HpcOmTaskGraph.contractNodesInGraph1 startNode: " + intString(List.last(contractNodes)) + "\n");
  startNode := List.last(contractNodes);
  deleteEntries := List.deleteMember(contractNodes,startNode); //all nodes which should be deleted
  //print("HpcOmTaskGraph.contractNodesInGraph1 deleteEntries: " + stringDelimitList(List.map(deleteEntries,intString),",") + "\n");
  deleteNodesParents := List.flatten(List.map1(deleteEntries, Array.getIndexFirst, graphInT));
  //print("HpcOmTaskGraph.contractNodesInGraph1 deleteNodesParents: " + stringDelimitList(List.map(deleteNodesParents,intString),",") + "\n");
  deleteNodesParents := List.sortedUnique(List.sort(deleteNodesParents, intGt),intEq);
  deleteNodesParents := List.setDifferenceOnTrue(deleteNodesParents, contractNodes, intEq);
  //print("HpcOmTaskGraph.contractNodesInGraph1 deleteNodesParents: " + stringDelimitList(List.map(deleteNodesParents,intString),",") + "\n");
  endNode := List.first(contractNodes);
  endChildren := arrayGet(graphIn,endNode); //all child-nodes of the end node
  //print("HpcOmTaskGraph.contractNodesInGraph1 endChildren: " + stringDelimitList(List.map(endChildren,intString),",") + "\n");
  startNodeChildren := arrayGet(graphIn, startNode);
  //print("HpcOmTaskGraph.contractNodesInGraph1 startNodeChildren_pre: " + stringDelimitList(List.map(startNodeChildren,intString),",") + "\n");
  startNodeChildren := List.setDifferenceOnTrue(startNodeChildren, deleteEntries, intEq);
  graphTmp := arrayUpdate(graphIn, startNode, startNodeChildren);
  //print("HpcOmTaskGraph.contractNodesInGraph1 startNodeChildren_post: " + stringDelimitList(List.map(startNodeChildren,intString),",") + "\n");
  graphTmp := List.fold2(deleteNodesParents, contractNodesInGraph2, deleteEntries, startNode, graphTmp);
  //print("HpcOmTaskGraph.contractNodesInGraph1 startnode: " + intString(startNode) + " endChildren: " + stringDelimitList(List.map(endChildren,intString),",") + "\n");
  graphTmp := arrayUpdate(graphIn,startNode,endChildren);
  graphOut := graphTmp;
end contractNodesInGraph1;

protected function contractNodesInGraph2
  input Integer iParentNode;
  input list<Integer> iDeletedNodes;
  input Integer iNewNodeIdx;
  input TaskGraph iGraph;
  output TaskGraph oGraph;
protected
  list<Integer> adjLstEntry;
algorithm
  adjLstEntry := arrayGet(iGraph,iParentNode);
  //print("contractNodesInGraph2 ParentNode: " + intString(iParentNode) + " adjLstEntry_Pre: " + stringDelimitList(List.map(adjLstEntry,intString),",") + "\n");
  adjLstEntry := List.setDifferenceOnTrue(adjLstEntry, iDeletedNodes, intEq);
  adjLstEntry := iNewNodeIdx :: adjLstEntry;
  adjLstEntry := List.sortedUnique(List.sort(adjLstEntry, intGt),intEq);
  //print("contractNodesInGraph2 ParentNode: " + intString(iParentNode) + " adjLstEntry_Post: " + stringDelimitList(List.map(adjLstEntry,intString),",") + "\n");
  oGraph := arrayUpdate(iGraph, iParentNode, adjLstEntry);
end contractNodesInGraph2;

protected function compareListLengthOnTrue " is true if given list has a length of inValue, otherwise false.
author: Waurich TUD 2013-07"
  input Integer inValue;
  input list<Integer> inLst;
  output Boolean equalLength;
algorithm
  equalLength := matchcontinue(inValue,inLst)
    case(_,_)
      equation
        true = intEq(inValue,listLength(inLst));
      then
        true;
    else false;
  end matchcontinue;
end compareListLengthOnTrue;

protected function getMergedSystemData " udpates the taskgraphmetadata for the merged system.
author:Waurich TUD 2013-07"
  input TaskGraphMeta graphDataIn;
  input list<list<Integer>> contractNodes;
  output TaskGraphMeta graphDataOut;
protected
  array<list<Integer>> inComps;
  array<tuple<Integer, Integer, Integer>> varCompMapping;
  array<tuple<Integer,Integer,Integer>> eqCompMapping;
  array<list<Integer>> compParamMapping;
  array<String> compNames;
  array<String> compDescs;
  array<tuple<Integer,Real>> exeCosts;
  array<Communications> commCosts;
  array<Integer> nodeMark;
  list<list<Integer>> inCompsLst;
  array<ComponentInfo> compInformations;
algorithm
  TASKGRAPHMETA(inComps=inComps, varCompMapping=varCompMapping, eqCompMapping=eqCompMapping, compParamMapping=compParamMapping, compNames=compNames, compDescs=compDescs, exeCosts=exeCosts, commCosts=commCosts, nodeMark=nodeMark, compInformations=compInformations) := graphDataIn;
  inComps := updateInCompsForMerging(inComps,contractNodes);
  compNames := List.fold2(List.intRange(arrayLength(compNames)),updateCompNamesForMerging,inComps,nodeMark,compNames);
  graphDataOut := TASKGRAPHMETA(inComps,varCompMapping,eqCompMapping,compParamMapping,compNames,compDescs,exeCosts,commCosts,nodeMark,compInformations);
end getMergedSystemData;

public function updateCompNamesForMerging " updates the compNames with the merging information.
author:Waurich TUD 2013-07"
  input Integer compIdx;
  input array<list<Integer>> inComps;
  input array<Integer> nodeMark;
  input array<String> compNamesIn;
  output array<String> compNamesOut;
algorithm
  compNamesOut := matchcontinue(compIdx,inComps,nodeMark,compNamesIn)
    local
      Integer unionNode;
      list<Integer> mergedComps;
      array<String> compNamesTmp;
      String compName;
    case(_,_,_,_)
      equation
        true = compIdx <= arrayLength(compNamesIn);
        unionNode = getCompInComps(compIdx,1,inComps,nodeMark); //TODO: that seems to be expensive, can we iterate over the nodes instead of the components?
        true = unionNode <> -1;
        mergedComps = arrayGet(inComps,unionNode);
        true = listLength(mergedComps) == 1;
      then
        compNamesIn;
    case(_,_,_,_)
      equation
       true = compIdx <= arrayLength(compNamesIn);
       unionNode = getCompInComps(compIdx,1,inComps,nodeMark);
       true = unionNode <> -1;
       mergedComps = arrayGet(inComps,unionNode);
       false = listLength(mergedComps) == 1;
       compName = "contracted comps "+stringDelimitList(List.map(mergedComps,intString),",");
       compNamesTmp = arrayUpdate(compNamesIn,compIdx,compName);
     then
       compNamesTmp;
     case(_,_,_,_)
      equation
       true = compIdx <= arrayLength(compNamesIn);
       unionNode = getCompInComps(compIdx,1,inComps,nodeMark);
       true = unionNode == -1;
     then
       compNamesIn;
     else
      equation
        print("updateCompNamesForMerging failed!\n");
      then fail();
   end matchcontinue;
end updateCompNamesForMerging;

protected function updateInCompsForMerging " updates the inComps with the merging information.
author:waurich TUD 2013-07"
  input array<list<Integer>> inCompsIn;
  input list<list<Integer>> mergedPaths; //nodes to contract
  output array<list<Integer>> inCompsOut;
protected
  array<list<Integer>> inCompsTmp;
  list<list<Integer>> inCompsLst;
  list<Integer> deleteNodes;
  list<Integer> startNodes;
algorithm
  //mergedPaths := List.map1(mergedPaths,List.sort,intGt);
  startNodes := List.map(mergedPaths,List.last);
  //startNodes := List.map(mergedPaths,List.first);
  (_,deleteNodes,_) := List.intersection1OnTrue(List.flatten(mergedPaths),startNodes,intEq);
  //deleteNodes := List.map(mergedPaths,List.rest);
  inCompsLst := arrayList(inCompsIn);
  inCompsLst := List.fold2(List.intRange(arrayLength(inCompsIn)),updateInComps1,(startNodes,deleteNodes,mergedPaths),inCompsIn,inCompsLst);
  inCompsLst := List.removeOnTrue({},equalLists,inCompsLst);
  //inCompsLst := List.map3(inCompsLst,getCompInComps,1,inComps,arrayCreate(arrayLength(inComps),0));
  inCompsOut := listArray(inCompsLst);
end updateInCompsForMerging;

protected function updateInComps1 " folding function for updateInComps.
author:waurich TUD 2013-07"
  input Integer nodeIdx;
  input tuple<list<Integer>,list<Integer>,list<list<Integer>>> mergeInfo; //<%startNodes,deleteNodes,mergedPaths%>
  input array<list<Integer>> primInComps;
  input list<list<Integer>> inCompLstIn;
  output list<list<Integer>> inCompLstOut;
algorithm
  inCompLstOut := matchcontinue(nodeIdx,mergeInfo,primInComps,inCompLstIn)
    local
      Integer mergeGroupIdx;
      list<Integer> inComps;
      Integer inComp;
      list<Integer> mergedSet, mergedNodes;
      list<Integer> startNodes;
      list<Integer> deleteNodes;
      list<list<Integer>> mergedPaths;
      list<list<Integer>> inCompLstTmp;
    case(_,_,_,_)
      // the given node is a startNode
      equation
        (startNodes,_,mergedPaths) = mergeInfo;
        //print("updateInComps1 startNodes:" + stringDelimitList(List.map(startNodes,intString),",") + "\n");
        //print("updateInComps1 deleteNodes:" + stringDelimitList(List.map(deleteNodes,intString),",") + "\n");
        //print("updateInComps1 first mergedPath:" + stringDelimitList(List.map(List.first(mergedPaths),intString),",") + "\n");
        inComps = listGet(inCompLstIn,nodeIdx);
        //print("updateInComps1 inComps:" + stringDelimitList(List.map(inComps,intString),",") + "\n");
        //true = listLength(inComps) == 1;
        _ = listGet(inComps,1);
        //print("updateInComps1 inComp:" + intString(inComp) + "\n");
        true = List.isMemberOnTrue(nodeIdx,startNodes,intEq);
        mergeGroupIdx = List.position(nodeIdx,startNodes);
        mergedNodes = listGet(mergedPaths,mergeGroupIdx);
        //print("updateInComps1 mergedNodes:" + stringDelimitList(List.map(mergedNodes,intString),",") + "\n");
        mergedSet = List.flatten(List.map1(mergedNodes,Array.getIndexFirst,primInComps));
        //print("updateInComps1 mergedSet:" + stringDelimitList(List.map(mergedSet,intString),",") + "\n");
        inCompLstTmp = List.fold(mergedNodes, updateInComps2, inCompLstIn);
        inCompLstTmp = List.replaceAt(mergedSet, nodeIdx, inCompLstTmp);
      then
        inCompLstTmp;
    else inCompLstIn;
  end matchcontinue;
end updateInComps1;

protected function updateInComps2 "Replaces the entry <%iNodeIdx - 1%> in inCompListIn with an empty set"
  input Integer iNodeIdx;
  input list<list<Integer>> inCompLstIn;
  output list<list<Integer>> inCompLstOut;
algorithm
  inCompLstOut := List.replaceAt({}, iNodeIdx, inCompLstIn);
end updateInComps2;

protected function equalLists " compares two lists and sets true if they are equal.
author:Waurich TUD 2013-07"
  input list<Integer> inList1;
  input list<Integer> inList2;
  output Boolean outIsEqual;
algorithm
  outIsEqual := matchcontinue(inList1, inList2)
    local
      Integer e1, e2;
      list<Integer> rest1, rest2;

    case ({}, {}) then true;
    case ({}, _) then false;
    case (_, {}) then false;
    case (e1 :: rest1, e2 :: rest2)
      equation
        true = intEq(e1,e2);
      then
        equalLists(rest1, rest2);
    else false;
  end matchcontinue;
end equalLists;

protected function findOneChildParents " fold function to find nodes or paths in the taskGraph with just one successor per node.
extended: adds endnodes without successor as well
author: Waurich TUD 2013-07"
  input list<Integer> allNodes;
  input TaskGraph graphIn;
  input list<Integer> doNotMerge;  // these nodes cannot be chosen
  input list<list<Integer>> lstIn;
  input Integer inPath;  // the current nodeIndex in a path of only cildren. if no path then 0.
  input array<Integer> contrNodes;
  output list<list<Integer>> lstOut;
algorithm
  lstOut := matchcontinue(allNodes,graphIn,doNotMerge,lstIn,inPath,contrNodes)
    local
      Integer child;
      Integer head;
      list<Integer> nodeChildren;
      list<Integer> parents;
      list<Integer> pathLst;
      list<Integer> rest;
      list<list<Integer>> lstTmp;
    case({},_,_,_,_,_)
      //checked all nodes
      equation
        then
          lstIn;
    case((head::rest),_,_,_,_,_)
      //check new node that has several children
      equation
        true = intEq(inPath,0);
        nodeChildren = arrayGet(graphIn,head);
        nodeChildren = filterContractedNodes(nodeChildren,contrNodes);
        //print("findOneChildParents: " + stringDelimitList(List.map(nodeChildren, intString), ",") + "\n");
        false = listLength(nodeChildren) == 1;
        //print("findOneChildParents case 1 for task " + intString(head) + ". Node children: " + stringDelimitList(List.map(nodeChildren, intString), ",") + "\n");
        lstTmp = findOneChildParents(rest,graphIn,doNotMerge,lstIn,0,contrNodes);
      then
        lstTmp;
    case((head::rest),_,_,_,_,_)
      //check new node that is excluded
      equation
        true = intEq(inPath,0);
        true = listMember(head,doNotMerge);
        //print("findOneChildParents case 2 for task " + intString(head) + "\n");
        lstTmp = findOneChildParents(rest,graphIn,doNotMerge,lstIn,0,contrNodes);
      then
        lstTmp;
    case((head::rest),_,_,_,_,_)
      // check new node that has only one child but this is excluded
      equation
        true = intEq(inPath,0);
        nodeChildren = arrayGet(graphIn,head);
        nodeChildren = filterContractedNodes(nodeChildren,contrNodes);
        true = listLength(nodeChildren) == 1;
        child = listGet(nodeChildren,1);
        true = listMember(child,doNotMerge);
        //print("findOneChildParents case 3 for task " + intString(head) + "\n");
        lstTmp = findOneChildParents(rest,graphIn,doNotMerge,lstIn,child,contrNodes);
      then
        lstTmp;
    case((head::rest),_,_,_,_,_)
      // check new node that has only one child , follow the path
      equation
        true = intEq(inPath,0);
        nodeChildren = arrayGet(graphIn,head);
        nodeChildren = filterContractedNodes(nodeChildren,contrNodes);
        true = listLength(nodeChildren) == 1;
        child = listGet(nodeChildren,1);
        lstTmp = {head}::lstIn;
        lstTmp = findOneChildParents(rest,graphIn,doNotMerge,lstTmp,child,contrNodes);
        //print("findOneChildParents case 4 for task " + intString(head) + ". Node children: " + stringDelimitList(List.map(nodeChildren, intString), ",") + "\n");
      then
        lstTmp;
    case((_::_),_,_,_,_,_)
      // dont follow because the path contains excluded nodes
      equation
        false = intEq(inPath,0);
        true = listMember(inPath,doNotMerge);
        //print("findOneChildParents case 5 for task " + intString(head) + "\n");
        lstTmp = findOneChildParents(allNodes,graphIn,doNotMerge,lstIn,0,contrNodes);
      then
        lstTmp;
    case((_::rest),_,_,_,_,_)
      // follow path and check that there is still only one child with just one parent
      equation
        false = intEq(inPath,0);
        nodeChildren = arrayGet(graphIn,inPath);
        nodeChildren = filterContractedNodes(nodeChildren,contrNodes);
        parents = getParentNodes(inPath,graphIn);
        parents = filterContractedNodes(parents,contrNodes);
        true = listLength(nodeChildren) == 1 and List.isNotEmpty(nodeChildren) and listLength(parents) == 1;
        //print("findOneChildParents case 6 for task " + intString(head) + "\n");
        child = listGet(nodeChildren,1);
        pathLst = List.first(lstIn);
        pathLst = inPath::pathLst;
        lstTmp = List.replaceAt(pathLst, 1, lstIn);
        rest = List.deleteMember(allNodes,inPath);
        lstTmp = findOneChildParents(rest,graphIn,doNotMerge,lstTmp,child,contrNodes);
      then
        lstTmp;
    case((_::rest),_,_,_,_,_)
      // follow path and check that there is an endnode without successor that will be added to the path
      equation
        false = intEq(inPath,0);
        nodeChildren = arrayGet(graphIn,inPath);
        nodeChildren = filterContractedNodes(nodeChildren,contrNodes);
        parents = getParentNodes(inPath,graphIn);
        parents = filterContractedNodes(parents,contrNodes);
        //true = List.isEmpty(nodeChildren) and listLength(parents) == 1;
        //print("findOneChildParents case 7 for task " + intString(head) + "\n");
        pathLst = List.first(lstIn);
        pathLst = inPath::pathLst;
        lstTmp = List.replaceAt(pathLst, 1, lstIn);
        rest = List.deleteMember(allNodes,inPath);
        lstTmp = findOneChildParents(rest,graphIn,doNotMerge,lstTmp,0,contrNodes);
      then
        lstTmp;
    /* case((head::rest),_,_,_,_,_)
      // follow path and check that there are more children or a child with more parents. end path before this node
      equation
        false = intEq(inPath,0);
        print("findOneChildParents case 8 for task " + intString(head) + "\n");
        lstTmp = findOneChildParents(allNodes,graphIn,doNotMerge,lstIn,0,contrNodes);
      then
        lstTmp; */
    else
      equation
        print("findOneChildParents failed\n");
      then
        fail();
  end matchcontinue;
end findOneChildParents;

protected function getParentNodes " function to get the parent nodes of a node.
author:Waurich TUD 2013-07"
  input Integer nodeIdx;
  input TaskGraph graphIn;
  output list<Integer> parentNodes;
protected
  TaskGraph graphInT;
algorithm
  graphInT := BackendDAEUtil.transposeMatrix(graphIn,arrayLength(graphIn));
  parentNodes := arrayGet(graphInT, nodeIdx);
end getParentNodes;

protected function checkParentNode "fold function to check the first element in the child path for the number of parent nodes.if the number is 1 the parent will be added.
author:Waurich TUD 2013-06"
  input Integer lstIdx;
  input TaskGraph graphIn;
  input list<list<Integer>> lstIn;
  output list<list<Integer>> lstOut;
algorithm
  lstOut := matchcontinue(lstIdx,graphIn,lstIn)
    local
      list<Integer> childLst;
      Integer child;
      Integer parent;
      list<Integer> parents;
      list<list<Integer>> lstTmp;
  case(_,_,_)
    equation
      childLst = listGet(lstIn,lstIdx);
      child = List.last(childLst);
      parents = getParentNodes(child,graphIn);
      true = intEq(listLength(parents),1);
      parent = listGet(parents,1);
      childLst = listReverse(childLst);
      childLst = parent :: childLst;
      childLst = listReverse(childLst);
      lstTmp = List.replaceAt(childLst, lstIdx, lstIn);
      then
        lstTmp;
  case(_,_,_)
    equation
      childLst = listGet(lstIn,lstIdx);
      child = List.last(childLst);
      parents = getParentNodes(child,graphIn);
      false = intEq(listLength(parents),1);
      then
        lstIn;
  end matchcontinue;
end checkParentNode;


//-----------------------------
//  Functions to generate costs
//-----------------------------

public function createCosts "author: marcusw
  Updates the given TaskGraphMeta-Structure with the calculated exec und communication costs."
  input BackendDAE.BackendDAE iDae;
  input String benchFilePrefix; //The prefix of the xml or json profiling-file
  input array<Integer> simeqCompMapping; //Map each simEq to the scc
  input TaskGraphMeta iTaskGraphMeta;
  output TaskGraphMeta oTaskGraphMeta;
protected
  array<BackendDAE.EqSystem> compMapping;
  array<tuple<BackendDAE.EqSystem,Integer>> compMapping_withIdx;
  BackendDAE.Shared shared;
  BackendDAE.StrongComponents comps;
  tuple<Integer,Integer> reqTimeCom;
  //These mappings are for simEqSystems
  list<tuple<Integer,Integer,Real>> reqTimeOpLstSimCode; //<simEqIdx,numberOfCalcs,calcTimeSum>
  array<tuple<Integer,Real>> reqTimeOpSimCode; //<simEqIdx,calcTime>
  TaskGraphMeta tmpTaskGraphMeta;
  array<Real> reqTimeOp; //Calculation time for each scc
  array<list<Integer>> inComps;
  array<Communications> commCosts;
algorithm
  oTaskGraphMeta := matchcontinue(iDae,benchFilePrefix,simeqCompMapping,iTaskGraphMeta)
    case(BackendDAE.DAE(shared=shared),_,_,TASKGRAPHMETA(inComps=inComps, commCosts=commCosts))
      equation
        (comps,compMapping_withIdx) = getSystemComponents(iDae);
        compMapping = Array.map(compMapping_withIdx, Util.tuple21);
        ((_,reqTimeCom)) = HpcOmBenchmark.benchSystem();
        reqTimeOpLstSimCode = HpcOmBenchmark.readCalcTimesFromFile(benchFilePrefix);
        //print("createCosts: read files\n");
        //print("createCosts: read values: " + stringDelimitList(List.map(List.map(reqTimeOpLstSimCode, Util.tuple33), realString), ",") + "\n");
        reqTimeOpSimCode = arrayCreate(listLength(reqTimeOpLstSimCode),(-1,-1.0));
        reqTimeOpSimCode = List.fold(reqTimeOpLstSimCode, createCosts1, reqTimeOpSimCode);
        //print("createCosts: reqTimeOpSimCode created\n");
        reqTimeOp = arrayCreate(listLength(comps),-1.0);
        reqTimeOp = convertSimEqToSccCosts(reqTimeOpSimCode, simeqCompMapping, reqTimeOp);
        //print("createCosts: scc costs converted\n");
        commCosts = createCommCosts(commCosts,1,reqTimeCom);
        ((_,tmpTaskGraphMeta)) = Array.fold4(inComps,createCosts0,(comps,shared),compMapping, reqTimeOp, reqTimeCom, (1,iTaskGraphMeta));
      then tmpTaskGraphMeta;
    else
      equation
        tmpTaskGraphMeta = estimateCosts(iDae,iTaskGraphMeta);
        print("Warning: The costs have been estimated. Maybe " + benchFilePrefix + "-file is missing.\n");
      then tmpTaskGraphMeta;
  end matchcontinue;
end createCosts;

public function estimateCosts "estimates the communication and execution costs very roughly so hpcom can work with something when there is no prof_xml
author: Waurich TUD 09-2013"
  input BackendDAE.BackendDAE daeIn;
  input TaskGraphMeta taskGraphMetaIn;
  output TaskGraphMeta taskGraphMetaOut;
protected
  array<list<Integer>> inComps;
  array<tuple<Integer, Integer, Integer>> varCompMapping;
  array<tuple<Integer,Integer,Integer>>  eqCompMapping;
  array<String> compNames;
  array<String> compDescs;
  array<tuple<Integer,Real>> exeCosts;
  array<Communications> commCosts;
  array<Integer> nodeMark;
  list<Integer> comNumLst;
  list<tuple<Integer,Real>> exeCostsLst;
  BackendDAE.EqSystems eqSystems;
  BackendDAE.Shared shared;
  list<BackendDAE.StrongComponents> compsLst;
  array<list<Integer>> compParamMapping;
  array<ComponentInfo> compInformations;
  Integer compIdx;
algorithm
  BackendDAE.DAE(eqs=eqSystems, shared=shared) := daeIn;
  compsLst := List.map(eqSystems,BackendDAEUtil.getStrongComponents);
  comNumLst := List.map(compsLst,listLength);
  TASKGRAPHMETA(inComps=inComps,varCompMapping=varCompMapping,eqCompMapping=eqCompMapping,compParamMapping=compParamMapping,compNames=compNames,compDescs=compDescs,exeCosts=exeCosts,commCosts=commCosts,nodeMark=nodeMark,compInformations=compInformations) := taskGraphMetaIn;
  // get the communication costs
  commCosts := getCommCostsOnly(commCosts);
  // estimate the executionCosts
  exeCostsLst := List.flatten(List.map3(List.intRange(listLength(compsLst)),estimateCosts0,compsLst,eqSystems,shared));

  //overwrite old values
  compIdx := 1;
  for exeCost in exeCostsLst loop
    arrayUpdate(exeCosts, compIdx, exeCost);
    compIdx := compIdx + 1;
  end for;

  taskGraphMetaOut := TASKGRAPHMETA(inComps,varCompMapping,eqCompMapping,compParamMapping,compNames,compDescs,exeCosts,commCosts,nodeMark,compInformations);
end estimateCosts;

protected function estimateCosts0 "estimates the exeCosts for StrongComponents
author: Waurich TUD 2013-09"
  input Integer systIdx;
  input list<BackendDAE.StrongComponents> compsLstIn;
  input BackendDAE.EqSystems eqSystemsIn;
  input BackendDAE.Shared sharedIn;
  output list<tuple<Integer,Real>> exeCostsOut;
protected
  BackendDAE.StrongComponents comps;
  BackendDAE.EqSystem eqSys;
  list<BackendDAE.CompInfo> compsInfos;
algorithm
  comps := listGet(compsLstIn,systIdx);
  eqSys := listGet(eqSystemsIn,systIdx);
  compsInfos := listReverse(BackendDAEOptimize.countOperationstraverseComps(comps,eqSys,sharedIn,{}));
  exeCostsOut := List.map(compsInfos,calculateCosts);
end estimateCosts0;

public function calculateCosts "calculates the estimated costs for a compInfo. this has been benchmarked using the Cpp runtime
author: Waurich TUD 2014-12"
  input BackendDAE.CompInfo compInfo;
  output tuple<Integer,Real> exeCost;
algorithm
  exeCost := matchcontinue(compInfo)
    local
      Integer numAdds,numMul,numDiv,numOth,numTrig,numRel,numLog,numFuncs, costs, ops,ops1, offset,size;
      Real allOpCosts,tornCosts,otherCosts,dens;
      BackendDAE.StrongComponent comp;
      BackendDAE.CompInfo allOps, torn, other;

    case(BackendDAE.COUNTER(comp=comp,numAdds=numAdds,numMul=numMul,numDiv=numDiv,numTrig=numTrig,numRelations=numRel,numLog=numLog,numOth=numOth,funcCalls=numFuncs))
      equation
        ops = numAdds+numMul+numOth+numTrig+numRel+numLog;
        if BackendDAEUtil.isSingleEquationComp(comp) then offset=35;
        elseif BackendDAEUtil.isWhenComp(comp) then offset=113;
        elseif BackendDAEUtil.isArrayComp(comp) then offset=100;
        else offset = 0;
        end if;
        costs = offset + 12*numAdds + 32*numMul + 37*numDiv + 236*numTrig + 2*numRel + 4*numLog + 110*numOth + 375*numFuncs;
     then (ops,intReal(costs));

    case(BackendDAE.SYSTEM(allOperations=_,size=size,density=dens))// density is in procent
      equation
        allOpCosts = realMul(0.049, realPow(realMul(intReal(size),(realAdd(1.0,realMul(dens,19.0)))),3.0));
      then (1, allOpCosts);

    case(BackendDAE.TORN_ANALYSE(tornEqs=torn,otherEqs=other,tornSize=size))
      equation
        (ops,tornCosts) = calculateCosts(torn);
        (ops1,otherCosts) = calculateCosts(other);
        allOpCosts = realAdd(realAdd(3000.0,realMul(7.62,realPow(intReal(size),3.0))),realAdd(realMul(2.0,tornCosts),realMul(1.4,otherCosts)));
      then (ops+ops1,allOpCosts);

    case(BackendDAE.NO_COMP(numAdds=numAdds,numMul=numMul,numDiv=numDiv,numTrig=numTrig,numRelations=numRel,numLog=numLog,numOth=numOth,funcCalls=numFuncs))
      equation
        ops = numAdds+numMul+numOth+numTrig+numRel+numLog;
        offset = 50;  // this was just estimated, not benchmarked
        costs = offset + 12*numAdds + 32*numMul + 37*numDiv + 236*numTrig + 2*numRel + 4*numLog + 110*numOth + 375*numFuncs;
     then (ops,intReal(costs));

      else
        equation
          print("calculate costs failed!\n");
        then (-1,-1.0);
  end matchcontinue;
end calculateCosts;

protected function getCommCostsOnly "function to compute the communicationCosts
author: Waurich TUD 2013-09"
  input array<Communications> commCostsIn;
  output array<Communications> commCostsOut;
protected
  tuple<Integer,Integer> reqTimeCom;
algorithm
  ((_,reqTimeCom)) := HpcOmBenchmark.benchSystem();
  commCostsOut := createCommCosts(commCostsIn,1,reqTimeCom);
end getCommCostsOnly;

protected function checkForExecutionCosts
  "checks if every entry in exeCosts is > 0.0"
  input TaskGraphMeta dataIn;
  output Boolean isFine;
protected
  array<list<Integer>> inComps;
  array<tuple<Integer,Real>> exeCosts;
algorithm
  TASKGRAPHMETA(inComps=inComps, exeCosts=exeCosts) := dataIn;
  isFine := checkForExecutionCosts1(exeCosts,inComps,1);
  if not isFine then
    print("There are execution costs with value 0.0!\n");
  end if;
end checkForExecutionCosts;

protected function checkForExecutionCosts1 "checks if the comp for the given node has an executionCost > 0.0
author: Waurich TUD 2013-09"
  input array<tuple<Integer,Real>> exeCosts;
  input array<list<Integer>> inComps;
  input Integer nodeIdx;
  output Boolean bOut;
algorithm
  bOut := matchcontinue(exeCosts,inComps,nodeIdx)
    local
      Boolean b, isZero;
      list<Integer> comps;
      Real value;
      tuple<Integer,Real> tpl;
    case(_,_,_)
      equation
        true = arrayLength(inComps) >= nodeIdx;
        comps = arrayGet(inComps,nodeIdx);
        isZero = List.fold1(comps,checkTpl2ForZero,exeCosts,false);
        false = isZero;
        b = checkForExecutionCosts1(exeCosts,inComps,nodeIdx+1);
      then
        b;
    case(_,_,_)
      equation
        true = arrayLength(inComps) < nodeIdx;
        then
          true;
    else
      equation
      then
        false;
  end matchcontinue;
end checkForExecutionCosts1;

protected function checkTpl2ForZero "folding function for checkForExecutionCosts1
author:Waurich TUD 2013-09"
  input Integer comp;
  input array<tuple<Integer,Real>> exeCosts;
  input Boolean bIn;
  output Boolean bOut;
protected
  Boolean b;
  Real value;
  tuple<Integer,Real> tpl;
algorithm
  tpl := arrayGet(exeCosts,comp);
  (_,value) := tpl;
  b := realEq(value,0.0);
  bOut := b or bIn;
end checkTpl2ForZero;

public function convertNodeListToEdgeTuples "author: marcusw
  Convert a list of nodes to a list of edged. E.g. {1,2,5} -> {(1,2),(2,5)}"
  input list<Integer> iNodeList;
  output list<tuple<Integer,Integer>> oEdgeList;
algorithm
  oEdgeList := convertNodeListToEdgeTuples0(iNodeList, listLength(iNodeList), {});
end convertNodeListToEdgeTuples;

protected function convertNodeListToEdgeTuples0 "author: marcusw
  Helper function of convertNodeListToEdgeTuples"
  input list<Integer> iNodeList;
  input Integer iNodeIdx;
  input list<tuple<Integer,Integer>> iEdgeList;
  output list<tuple<Integer,Integer>> oEdgeList;
protected
  list<tuple<Integer,Integer>> tmpEdgeList;
  Integer elem, preElem;
algorithm
  oEdgeList := matchcontinue(iNodeList,iNodeIdx,iEdgeList)
    case(_,_,tmpEdgeList)
      equation
        true = intGt(iNodeIdx, 1);
        elem = listGet(iNodeList, iNodeIdx);
        preElem = listGet(iNodeList, iNodeIdx-1);
        tmpEdgeList = (preElem,elem)::tmpEdgeList;
        tmpEdgeList = convertNodeListToEdgeTuples0(iNodeList, iNodeIdx-1,tmpEdgeList);
      then tmpEdgeList;
    else iEdgeList;
  end matchcontinue;
end convertNodeListToEdgeTuples0;

protected function convertSimEqToSccCosts
  input array<tuple<Integer,Real>> iReqTimeOpSimCode;
  input array<Integer> iSimeqCompMapping; //Map each simEq to the scc
  input array<Real> iReqTimeOp;
  output array<Real> oReqTimeOp; //calcTime for each scc
algorithm
  ((_,oReqTimeOp)) := Array.fold1(iReqTimeOpSimCode, convertSimEqToSccCosts1, iSimeqCompMapping, (1,iReqTimeOp));
end convertSimEqToSccCosts;

protected function convertSimEqToSccCosts1
  input tuple<Integer,Real> iReqTimeOpSimCode;
  input array<Integer> iSimeqCompMapping; //Map each simEq to the scc
  input tuple<Integer,array<Real>> iReqTimeOp;
  output tuple<Integer,array<Real>> oReqTimeOp; //<simEqIdx, calcTime>
protected
  Integer simEqCalcCount, simEqIdx;
  Real simEqCalcTime, realSimEqCalcCount;
  array<Real> reqTime;
algorithm
  oReqTimeOp := matchcontinue(iReqTimeOpSimCode,iSimeqCompMapping,iReqTimeOp)
    case((simEqCalcCount, simEqCalcTime),_,(simEqIdx,reqTime))
      equation
        realSimEqCalcCount = intReal(simEqCalcCount);
        true = realNe(realSimEqCalcCount,0.0);
        reqTime = convertSimEqToSccCosts2(reqTime, realDiv(simEqCalcTime,realSimEqCalcCount), simEqIdx, iSimeqCompMapping);
      then ((simEqIdx+1,reqTime));
    case((simEqCalcCount, simEqCalcTime),_,(simEqIdx,reqTime))
      equation
        realSimEqCalcCount = intReal(simEqCalcCount);
        reqTime = convertSimEqToSccCosts2(reqTime, 0.0, simEqIdx, iSimeqCompMapping);
      then ((simEqIdx+1,reqTime));
    else
      equation
        print("convertSimEqToSccCosts1 failed!\n");
      then fail();
  end matchcontinue;
end convertSimEqToSccCosts1;

protected function convertSimEqToSccCosts2
  input array<Real> iReqTime;
  input Real iSimEqCalcTime;
  input Integer iSimEqIdx;
  input array<Integer> iSimeqCompMapping; //Map each simEq to the scc
  output array<Real> oReqTime;
protected
  array<Real> reqTime;
  Integer sccIdx;
algorithm
  oReqTime := matchcontinue(iReqTime,iSimEqCalcTime, iSimEqIdx, iSimeqCompMapping)
    case(reqTime,_,_,_)
      equation
        true = intGe(arrayLength(iSimeqCompMapping),iSimEqIdx);
        sccIdx = arrayGet(iSimeqCompMapping, iSimEqIdx);
        true = intGt(sccIdx,0);
        reqTime = arrayUpdate(reqTime,sccIdx, iSimEqCalcTime);
        //print("convertSimEqToSccCosts2 sccIdx: " + intString(sccIdx) + " simEqIdx: " + intString(iSimEqIdx) + " reqTime: " + realString(iSimEqCalcTime) + "\n");
      then
        reqTime;
    else iReqTime;
  end matchcontinue;
end convertSimEqToSccCosts2;

protected function createCosts0 "author: marcusw
  Updates the given TaskGraphMeta-Structure with the calculated exec und communication costs."
  input list<Integer> iNode; //Node to sccs mapping
  input tuple<BackendDAE.StrongComponents,BackendDAE.Shared> iComps_shared;
  input array<BackendDAE.EqSystem> iCompMapping;
  input array<Real> reqTimeOp;
  input tuple<Integer,Integer> reqTimeCom;
  input tuple<Integer,TaskGraphMeta> iTaskGraphMeta; //Node number and task graph meta
  output tuple<Integer,TaskGraphMeta> oTaskGraphMeta;
protected
  array<tuple<Integer, Integer, Integer>> varCompMapping;
  array<tuple<Integer,Integer,Integer>>  eqCompMapping;
  array<list<Integer>> compParamMapping;
  array<Integer> nodeRefCount;
  array<tuple<Integer,Real>> execCosts;
  BackendDAE.EqSystem comp;
  array<String> compNames, compDescs;
  array<list<Integer>> inComps;
  array<Communications> commCosts;
  Integer nodeNumber;
  TaskGraphMeta taskGraphMeta;
  array<ComponentInfo> compInformations;
algorithm
  (nodeNumber,taskGraphMeta) := iTaskGraphMeta;
  TASKGRAPHMETA(inComps=inComps,varCompMapping=varCompMapping,eqCompMapping=eqCompMapping,compParamMapping=compParamMapping,compNames=compNames,compDescs=compDescs,exeCosts=execCosts,commCosts=commCosts,nodeMark=nodeRefCount,compInformations=compInformations) := taskGraphMeta;
  createExecCost(iNode, iComps_shared, reqTimeOp, execCosts, iCompMapping, nodeNumber);
  oTaskGraphMeta := ((nodeNumber+1, TASKGRAPHMETA(inComps,varCompMapping,eqCompMapping,compParamMapping,compNames,compDescs,execCosts,commCosts,nodeRefCount,compInformations)));
end createCosts0;

protected function createCosts1 "author: marcusw
  Updates the requiredTime-array at the simEq-Position with the given calc-values."
  input tuple<Integer,Integer,Real> iTuple; //<simEqIdx,numberOfCalcs,calcTimeSum>
  input array<tuple<Integer,Real>> iReqTime;
  output array<tuple<Integer,Real>> oReqTime;
protected
  array<tuple<Integer,Real>> tmpArray;
  Integer simEqIdx,calcTimeCount;
  Real calcTime;
algorithm
  oReqTime := match(iTuple, iReqTime)
    case((0,calcTimeCount,calcTime),_)
      then iReqTime;
    case((simEqIdx,calcTimeCount,calcTime),tmpArray)
      equation
        //print("createCosts1: simEqIdx: " + intString(simEqIdx) + " calc-time: " + realString(calcTime) + " array-length: " + intString(arrayLength(iReqTime)) + "\n");
        tmpArray = arrayUpdate(iReqTime, simEqIdx,(calcTimeCount,calcTime));
      then tmpArray;
  end match;
end createCosts1;

protected function createExecCost "author: marcusw
  This method fills the iExecCosts array with the execution cost of each scc."
  input list<Integer> iNodeSccs; //Sccs of the current node
  input tuple<BackendDAE.StrongComponents, BackendDAE.Shared> icomps_shared; //input components and shared
  input array<Real> iRequiredTime; //required time for op
  input array<tuple<Integer,Real>> iExecCosts; //<numberOfOperations, requiredCycles>
  input array<BackendDAE.EqSystem> compMapping;
  input Integer iNodeIdx;
algorithm
  _ :=  matchcontinue(iNodeSccs,icomps_shared,iRequiredTime,iExecCosts,compMapping,iNodeIdx)
    local
      tuple<Integer,Real> execCost;
    case(_,_,_,_,_,_)
      equation
        //print("\tcreateExecCost: sccs: " + stringDelimitList(List.map(iNodeSccs, intString), ",") + "\n");
        execCost = List.fold3(iNodeSccs, createExecCost0, icomps_shared, compMapping, iRequiredTime, (0,0.0));
        arrayUpdate(iExecCosts,iNodeIdx,execCost);
      then ();
    else ();
  end matchcontinue;
end createExecCost;

protected function createExecCost0 "author: marcusw
  Helper function for createExecCosts. It calculates the execution costs for the given scc and adds it to the iCosts parameter."
  input Integer sccIndex;
  input tuple<BackendDAE.StrongComponents, BackendDAE.Shared> icomps_shared; //input system and shared
  input array<BackendDAE.EqSystem> compMapping;
  input array<Real> iRequiredTime; //required time for op
  input tuple<Integer,Real> iCosts; //<numberOfOperations, requiredCycles>
  output tuple<Integer,Real> oCosts; //<numberOfOperations, requiredCycles>
protected
  Integer costAdd,costMul,costTrig;
  Integer iCosts_op;
  Real iCosts_cyc;
  BackendDAE.StrongComponent comp;
  BackendDAE.StrongComponents comps;
  BackendDAE.EqSystem syst;
  BackendDAE.Shared shared;
  Real reqTime;
algorithm
  (comps,shared) := icomps_shared;
  (iCosts_op, iCosts_cyc) := iCosts;
  comp := listGet(comps,sccIndex);
  syst := arrayGet(compMapping,sccIndex);
  reqTime := arrayGet(iRequiredTime, sccIndex);
  //print("createExecCost0: Handling scc " + intString(sccIndex) + " with cost " + realString(reqTime) + "\n");
  //((costAdd,costMul,costTrig)) := countOperations(comp, syst, shared);
  oCosts := (-100 + iCosts_op, realAdd(iCosts_cyc,reqTime));
end createExecCost0;

protected function createCommCosts "author: marcusw
  Extend the given commCost values with a concrete cycle-count."
  input array<Communications> iCosts;
  input Integer iCurrentIndex;
  input tuple<Integer,Integer> iReqTimeCom; //the required cycles to share x-values between two cores. The number of cycles is described as linear function y=m*x+1 (first value is m, second n).
  output array<Communications> oCosts;
protected
  array<Communications> tmpCosts;
  Communications currentCom;
algorithm
  oCosts := matchcontinue(iCosts, iCurrentIndex, iReqTimeCom)
    case(tmpCosts,_,_)
      equation
        true = intLe(iCurrentIndex, arrayLength(iCosts));
        currentCom = arrayGet(tmpCosts,iCurrentIndex);
        currentCom = List.map1(currentCom,createCommCosts0,iReqTimeCom);
        tmpCosts = arrayUpdate(tmpCosts,iCurrentIndex,currentCom);
        tmpCosts = createCommCosts(tmpCosts, iCurrentIndex+1,iReqTimeCom);
      then tmpCosts;
    else iCosts;
  end matchcontinue;
end createCommCosts;

protected function createCommCosts0 "author: marcusw
  Helper function for createCommCosts to add the concrete cycle-count to the given communication."
  input Communication iComm;
  input tuple<Integer,Integer> iReqTimeCom;
  output Communication oComm;
protected
  Integer childNode,reqTimeM,reqTimeN;
  Integer numberOfVars;
  Real requiredTime;
  list<Integer> integerVars,floatVars,booleanVars,stringVars;
algorithm
  COMMUNICATION(numberOfVars=numberOfVars,integerVars=integerVars,floatVars=floatVars,booleanVars=booleanVars,stringVars=stringVars,childNode=childNode,requiredTime=requiredTime) := iComm;
  (reqTimeM,reqTimeN) := iReqTimeCom;
  requiredTime := intReal(reqTimeN + numberOfVars*reqTimeM);
  oComm := COMMUNICATION(numberOfVars,integerVars,floatVars,booleanVars,stringVars,childNode,requiredTime);
end createCommCosts0;

//---------------------------------
//  Functions to validate the graph
//---------------------------------

public function validateTaskGraphMeta "author: marcusw
  Check if the given TaskGraphMeta-object has a valid structure."
  input TaskGraphMeta iMeta;
  input BackendDAE.BackendDAE iDae;
  output Boolean valid;
algorithm
  valid := matchcontinue(iMeta, iDae)
    local
      BackendDAE.StrongComponents systComps, graphComps;
      array<BackendDAE.StrongComponent> systCompsArray;
      array<tuple<BackendDAE.EqSystem,Integer>> systCompEqSysMapping, graphCompEqSysMapping; //Map each component to the EqSystem
      list<tuple<BackendDAE.StrongComponent,Integer>> systCompEqSysMappingIdx, graphCompEqSysMappingIdx;
    case(_,_)
      equation
        //Check if all StrongComponents are in the graph
        (systComps,systCompEqSysMapping) = getSystemComponents(iDae);
        systCompsArray = listArray(systComps);
        (graphComps,graphCompEqSysMapping) = getGraphComponents(iMeta,systCompsArray,systCompEqSysMapping);
        ((_,_,systCompEqSysMappingIdx)) = validateTaskGraphMeta0(systCompEqSysMapping,(1,systComps,{}));
        ((_,_,graphCompEqSysMappingIdx)) = validateTaskGraphMeta0(graphCompEqSysMapping,(1,graphComps,{}));
        true = validateComponents(graphCompEqSysMappingIdx,systCompEqSysMappingIdx);
        //Check if no component was connected twice
        true = checkForDuplicates(graphCompEqSysMappingIdx);
        //Check if compNames,compDescs and exeCosts-array have the right size
        true = checkForExecutionCosts(iMeta);
        // Check if every node has an execution cost > 0.
      then true;
    else false;
  end matchcontinue;
end validateTaskGraphMeta;

public function validateTaskGraphMeta0 "author: marcusw
  Implementation of validateTaskGraphMeta."
  input array<tuple<BackendDAE.EqSystem,Integer>> iEqSysMapping;
  input tuple<Integer,BackendDAE.StrongComponents,list<tuple<BackendDAE.StrongComponent,Integer>>> iCompsTpl; //<current Index, list of remaining strong components, result>
  output tuple<Integer,BackendDAE.StrongComponents,list<tuple<BackendDAE.StrongComponent,Integer>>> oCompsTpl;
protected
  Integer currentIdx, eqSysIdx;
  BackendDAE.StrongComponents iComps, rest;
  BackendDAE.StrongComponent head;
  list<tuple<BackendDAE.StrongComponent,Integer>> iCompEqSysMapping, oCompEqSysMapping;
  tuple<Integer,BackendDAE.StrongComponents,list<tuple<BackendDAE.StrongComponent,Integer>>> tmpCompsTpl;
algorithm
  oCompsTpl := match(iEqSysMapping,iCompsTpl)
    case(_,(currentIdx,(head::rest),iCompEqSysMapping))
      equation
        ((_,eqSysIdx)) = arrayGet(iEqSysMapping,currentIdx);
        oCompEqSysMapping = (head,eqSysIdx)::iCompEqSysMapping;
        tmpCompsTpl = validateTaskGraphMeta0(iEqSysMapping,(currentIdx+1,rest,oCompEqSysMapping));
      then tmpCompsTpl;
    else iCompsTpl;
  end match;
end validateTaskGraphMeta0;

protected function validateComponents "author: marcusw
  Checks if the given component-lists are equal."
  input list<tuple<BackendDAE.StrongComponent,Integer>> graphComps; //<component, eqSysIdx>
  input list<tuple<BackendDAE.StrongComponent,Integer>> systComps;
  output Boolean res;
protected
  list<tuple<BackendDAE.StrongComponent,Integer>> sortedGraphComps, sortedSystComps;
algorithm
  res := matchcontinue(graphComps,systComps)
    case(_,_)
      equation
        sortedGraphComps = List.sort(graphComps,compareComponents);
        sortedSystComps = List.sort(systComps,compareComponents);
        true = List.isEqual(sortedGraphComps, sortedSystComps, true);
      then true;
    else
      equation
        print("Different components in graph and system");
      then false;
  end matchcontinue;
end validateComponents;

protected function checkForDuplicates "author: marcusw
  Returns true if every component is unique in the list."
  input list<tuple<BackendDAE.StrongComponent,Integer>> iComps; //<component, eqSysIdx>
  output Boolean res;
protected
  list<tuple<BackendDAE.StrongComponent,Integer>> sortedComps;
algorithm
  sortedComps := List.sort(iComps,compareComponents);
  //print("checkForDuplicates Components: " + stringDelimitList(List.map(sortedComps,BackendDump.printComponent), ";") + "\n");
  ((res,_)) := List.fold(sortedComps,checkForDuplicates0,(true,NONE()));
end checkForDuplicates;

protected function checkForDuplicates0 "author: marcusw
  Implementation of checkForDuplicates."
  input tuple<BackendDAE.StrongComponent,Integer> currentComp_idx;
  input tuple<Boolean,Option<tuple<BackendDAE.StrongComponent,Integer>>> iLastComp; //<result,lastComp>
  output tuple<Boolean,Option<tuple<BackendDAE.StrongComponent,Integer>>> oLastComp; //<result,lastComp>
protected
  BackendDAE.StrongComponent lastComp,currentComp;
  tuple<BackendDAE.StrongComponent,Integer> lastComp_idx;
  Integer idxLast, idxCurrent;
algorithm
  oLastComp := matchcontinue(currentComp_idx,iLastComp)
    case(_,(false,_)) then ((false,SOME(currentComp_idx)));
    case(_,(_,NONE())) then ((true,SOME(currentComp_idx)));
    case((currentComp,idxCurrent),(_,SOME(lastComp_idx as (lastComp, idxLast))))
      equation
        false = compareComponents(currentComp_idx,lastComp_idx);
        print("Component duplicate detected in eqSystem " + intString(idxCurrent) + ": current: " + BackendDump.printComponent(currentComp) + " last " + BackendDump.printComponent(lastComp) + ".\n");
      then ((false,SOME(currentComp_idx)));
    else ((true, SOME(currentComp_idx)));
  end matchcontinue;
end checkForDuplicates0;

protected function getGraphComponents "author: marcusw
  Returns all StrongComponents of the TaskGraphMeta-structure."
  input TaskGraphMeta iTaskGraphMeta;
  input array<BackendDAE.StrongComponent> iSystComps;
  input array<tuple<BackendDAE.EqSystem,Integer>> iCompEqSysMapping; //maps each iSystComps to <eqsystem,eqSystemIdx>
  output BackendDAE.StrongComponents oComps;
  output array<tuple<BackendDAE.EqSystem,Integer>> oCompEqGraphMapping;
protected
  BackendDAE.StrongComponents tmpComps;
  list<tuple<BackendDAE.EqSystem,Integer>> tmpMapping;
  array<list<Integer>> inComps;
  array<Integer> nodeMarks;
algorithm
  tmpComps := {};
  tmpMapping := {};
  TASKGRAPHMETA(inComps=inComps, nodeMark=nodeMarks) := iTaskGraphMeta;
  ((tmpComps,tmpMapping)) := Array.fold2(inComps,getGraphComponents0,iSystComps,iCompEqSysMapping,(tmpComps,tmpMapping));
  ((_,(tmpComps,tmpMapping))) := Array.fold2(nodeMarks,getGraphComponents2, iSystComps, iCompEqSysMapping, (1,(tmpComps,tmpMapping)));
  oComps := tmpComps;
  oCompEqGraphMapping := listArray(tmpMapping);
end getGraphComponents;

protected function getGraphComponents0 "author: marcusw
  Helper function of getGraphComponents. Returns all components which are not marked with -1 (all components that are part of the graph)."
  input list<Integer> inComp;
  input array<BackendDAE.StrongComponent> systComps;
  input array<tuple<BackendDAE.EqSystem,Integer>> iCompEqSysMapping;
  input tuple<BackendDAE.StrongComponents, list<tuple<BackendDAE.EqSystem,Integer>>> iNodeComps_Mapping; //list of components and list of mapping
  output tuple<BackendDAE.StrongComponents, list<tuple<BackendDAE.EqSystem,Integer>>> oNodeComps_Mapping;
protected
  BackendDAE.StrongComponents iNodeComps, tmpNodeComps;
  list<tuple<BackendDAE.EqSystem,Integer>> iCompsMapping, tmpCompsMapping;
algorithm
  (iNodeComps,iCompsMapping) := iNodeComps_Mapping;
  ((tmpNodeComps,tmpCompsMapping)) := List.fold2(inComp, getGraphComponents1, systComps, iCompEqSysMapping, ({},{}));
  tmpNodeComps := listAppend(iNodeComps,tmpNodeComps);
  tmpCompsMapping := listAppend(iCompsMapping,tmpCompsMapping);
  oNodeComps_Mapping := (tmpNodeComps,tmpCompsMapping);
end getGraphComponents0;

protected function getGraphComponents1
  input Integer compIdx;
  input array<BackendDAE.StrongComponent> systComps;
  input array<tuple<BackendDAE.EqSystem,Integer>> iCompEqSysMapping;
  input tuple<BackendDAE.StrongComponents, list<tuple<BackendDAE.EqSystem,Integer>>> iNodeComps_Mapping;
  output tuple<BackendDAE.StrongComponents, list<tuple<BackendDAE.EqSystem,Integer>>> oNodeComps_Mapping;
protected
  BackendDAE.StrongComponent comp;
  tuple<BackendDAE.EqSystem,Integer> eqSyst;
  BackendDAE.StrongComponents tmpComps;
  list<tuple<BackendDAE.EqSystem,Integer>> tmpSysts;
algorithm
  (tmpComps,tmpSysts) := iNodeComps_Mapping;
  comp := arrayGet(systComps,compIdx);
  eqSyst := arrayGet(iCompEqSysMapping,compIdx);
  tmpComps := comp::tmpComps;
  tmpSysts := eqSyst::tmpSysts;
  oNodeComps_Mapping := (tmpComps,tmpSysts);
end getGraphComponents1;

protected function getGraphComponents2 "author: marcusw
  Append all components with mark -1 to the componentlist."
  input Integer nodeMark;
  input array<BackendDAE.StrongComponent> systComps;
  input array<tuple<BackendDAE.EqSystem,Integer>> iCompEqSysMapping;
  input tuple<Integer,tuple<BackendDAE.StrongComponents, list<tuple<BackendDAE.EqSystem,Integer>>>> iNodeComps_Mapping; //<nodeIdx, <components,eqSystems>>
  output tuple<Integer,tuple<BackendDAE.StrongComponents, list<tuple<BackendDAE.EqSystem,Integer>>>> oNodeComps_Mapping;
protected
  Integer nodeIdx;
  BackendDAE.StrongComponent comp;
  tuple<BackendDAE.EqSystem,Integer> eqSyst;
  BackendDAE.StrongComponents comps;
  list<tuple<BackendDAE.EqSystem,Integer>> eqSysts;
algorithm
  oNodeComps_Mapping := matchcontinue(nodeMark, systComps, iCompEqSysMapping, iNodeComps_Mapping)
    case(_,_,_,(nodeIdx,(comps,eqSysts)))
      equation
        true = intGe(nodeMark,0);
      then ((nodeIdx+1,(comps,eqSysts)));
    case(_,_,_,(nodeIdx,(comps,eqSysts)))
      equation
        true = intEq(nodeMark,-2);
      then ((nodeIdx+1,(comps,eqSysts)));
    case(_,_,_,(nodeIdx,(comps,eqSysts)))
      equation
        comp = arrayGet(systComps,nodeIdx);
        eqSyst = arrayGet(iCompEqSysMapping,nodeIdx);
        comps = comp :: comps;
        eqSysts = eqSyst :: eqSysts;
      then ((nodeIdx+1,(comps,eqSysts)));
  end matchcontinue;
end getGraphComponents2;

protected function compareComponents "author: marcusw
  Compares the given components and returns false if they are equal."
  input tuple<BackendDAE.StrongComponent,Integer> iComp1;
  input tuple<BackendDAE.StrongComponent,Integer> iComp2; //<component, eqSystIdx>
  output Boolean res;
protected
  String comp1Str,comp2Str;
  Integer minLength, comp1Idx, comp2Idx;
  BackendDAE.StrongComponent comp1, comp2;
algorithm
  (comp1, comp1Idx) := iComp1;
  (comp2, comp2Idx) := iComp2;
  comp1Str := BackendDump.printComponent(comp1) + "_" + intString(comp1Idx);
  comp2Str := BackendDump.printComponent(comp2) + "_" + intString(comp2Idx);
  minLength := intMin(stringLength(comp1Str),stringLength(comp2Str));
  res := intGt(System.strncmp(comp1Str, comp2Str, minLength), 0);
end compareComponents;


//------------------------------------
//  Evaluation and analysing functions
//------------------------------------

public function getCriticalPaths " function to assign levels to the nodes of a graph and compute the criticalPath.
author: Waurich TUD 2013-07"
  input TaskGraph graphIn;
  input TaskGraphMeta graphDataIn;
  output tuple<list<list<Integer>>,Real> criticalPathOut; //criticalPath with communication costs <%paths, opCost%>
  output tuple<list<list<Integer>>,Real> criticalPathOutWoC; //criticalPath without communication costs <%paths, opCost%>
algorithm
  (criticalPathOut,criticalPathOutWoC) := matchcontinue(graphIn,graphDataIn)
    local
      list<Integer> rootNodes;
      list<list<Integer>> cpWCpaths,CpWoCpaths, level;
      Real cpWCcosts,cpWoCcosts;
      array<Integer> nodeMark;
    case(_,TASKGRAPHMETA())
      equation
        true = arrayLength(graphIn) <> 0;
        rootNodes = getRootNodes(graphIn);

        (cpWCpaths,cpWCcosts) = getCriticalPath(graphIn,graphDataIn,rootNodes,true);
        (CpWoCpaths,cpWoCcosts) = getCriticalPath(graphIn,graphDataIn,rootNodes,false);
        cpWCcosts = roundReal(cpWCcosts,2);
        cpWoCcosts = roundReal(cpWoCcosts,2);
      then
        ((cpWCpaths,cpWCcosts),(CpWoCpaths,cpWoCcosts));
    case(_,_)
      equation
        true = arrayLength(graphIn) == 0;
      then
        (({{}},0.0),({{}},0.0));
    else
      equation
        print("getCriticalPaths failed!\n");
      then
        (({{}},0.0),({{}},0.0));
  end matchcontinue;
end getCriticalPaths;

protected function getCriticalPath "function getCriticalPath
  author: marcusw
  Get the critical path of the graph."
  input TaskGraph iGraph;
  input TaskGraphMeta iGraphData;
  input list<Integer> iRootNodes;
  input Boolean iHandleCommCosts; //true if the communication costs should be handled
  output list<list<Integer>> oCriticalPathsOut; //The list of critical paths -> has only one element
  output Real oCpCosts;
protected
  array<tuple<Real,list<Integer>>> nodeCriticalPaths; //<criticalPath,criticalPathSuccessor> for each node <%idx%>
  list<tuple<Real,list<Integer>>> criticalPaths;
  Integer criticalPathIdx;
  list<Integer> criticalPath;
algorithm
  nodeCriticalPaths := arrayCreate(arrayLength(iGraph), (-1.0,{}));
  criticalPaths := List.map4(iRootNodes, getCriticalPath1, iGraph, iGraphData, iHandleCommCosts, nodeCriticalPaths);
  criticalPathIdx := getCriticalPath2(criticalPaths, 1, -1.0, -1);
  ((oCpCosts, criticalPath)) := listGet(criticalPaths, criticalPathIdx);
  //print("getCriticalPath: critical path " + stringDelimitList(List.map(criticalPath, intString), ",") + " with cost of: " + realString(oCpCosts) + ". Including communication costs: " + boolString(iHandleCommCosts) + "\n");
  oCriticalPathsOut := {criticalPath};
end getCriticalPath;

protected function getCriticalPath1 "function getCriticalPath1
  author: marcusw
  Get the critical path of the given node (iNode). If the node was already visited, the result will be read from the iNodeCriticalPaths.
  If the node is visited the first time, then the critical path is calculated and stored into the iNodeCriticalPaths-array."
  input Integer iNode;
  input TaskGraph iGraph;
  input TaskGraphMeta iGraphData;
  input Boolean iHandleCommCosts; //true if the communication costs should be handled
  input array<tuple<Real,list<Integer>>> iNodeCriticalPaths;
  output tuple<Real,list<Integer>> criticalPathOut;
protected
  Real cpCalcTime, calcTime, commTime;
  Integer criticalPathIdx;
  Communication commCost;
  list<Integer> childNodes, criticalPathChild, criticalPath, nodeComps;
  list<tuple<Real,list<Integer>>> criticalPaths;
  array<tuple<Integer,Real>> exeCosts;
  array<list<Integer>> inComps;
algorithm
  criticalPathOut := matchcontinue(iNode, iGraph, iGraphData, iHandleCommCosts, iNodeCriticalPaths)
    case(_,_,TASKGRAPHMETA(inComps=inComps,exeCosts=exeCosts),_,_)
      equation //In this case, the node was already visited
        ((cpCalcTime,criticalPath)) = arrayGet(iNodeCriticalPaths, iNode);
        true = realGe(cpCalcTime, 0.0);
      then ((cpCalcTime, criticalPath));
    case(_,_,TASKGRAPHMETA(inComps=inComps,exeCosts=exeCosts),_,_)
      equation //critical path of node is currently unknown -> calculate it
        childNodes = arrayGet(iGraph, iNode);
        true = List.isNotEmpty(childNodes); //has children
        criticalPaths = List.map4(childNodes, getCriticalPath1, iGraph, iGraphData, iHandleCommCosts, iNodeCriticalPaths);
        criticalPathIdx = getCriticalPath2(criticalPaths, 1, -1.0, -1);
        ((cpCalcTime, criticalPathChild)) = listGet(criticalPaths, criticalPathIdx);
        criticalPath = iNode :: criticalPathChild;
        commCost = if iHandleCommCosts then getCommCostBetweenNodes(iNode, List.first(criticalPathChild), iGraphData) else COMMUNICATION(0,{},{},{},{},-1,0.0);
        //print("Comm cost from node " + intString(iNode) + " to " + intString(List.first(criticalPathChild)) + " with costs " + intString(Util.tuple33(commCost)) + "\n");
        nodeComps = arrayGet(inComps, iNode);
        calcTime = addUpExeCostsForNode(nodeComps, exeCosts, 0.0); //sum up calc times of all components
        calcTime = realAdd(cpCalcTime,calcTime);
        COMMUNICATION(requiredTime=commTime) = commCost;
        //print("getCriticalPath1: " + " (" + realString(calcTime) + "+" + realString(commTime) + ")\n");
        calcTime = realAdd(calcTime, commTime);
        arrayUpdate(iNodeCriticalPaths, iNode, (calcTime, criticalPath));
        //print("getCriticalPath1: Critical path of node " + intString(iNode) + " is " + realString(calcTime) + "\n");
      then ((calcTime, criticalPath));
    case(_,_,TASKGRAPHMETA(inComps=inComps,exeCosts=exeCosts),_,_)
      equation //critical path of node is currently unknown -> calculate it
        childNodes = arrayGet(iGraph, iNode);
        false = List.isNotEmpty(childNodes); //has no children
        criticalPath = iNode :: {};
        nodeComps = arrayGet(inComps, iNode);
        calcTime = addUpExeCostsForNode(nodeComps, exeCosts, 0.0); //sum up calc times of all components
        arrayUpdate(iNodeCriticalPaths, iNode, (calcTime, criticalPath));
      then ((calcTime, criticalPath));
    else
      equation
        print("HpcOmTaskGraph.getCriticalPath_1 failed\n");
      then fail();
  end matchcontinue;
end getCriticalPath1;

protected function getCriticalPath2 "function getCriticalPath2
  author: marcusw
  Find the list-index of the longest path. The paths which should be compared have to be stored in the iCriticalPaths-list."
  input list<tuple<Real,list<Integer>>> iCriticalPaths;
  input Integer iListIdx;
  input Real iLongestPath;
  input Integer iLongestPathIndex;
  output Integer oLongestPathIndex;
protected
  Real cpCost;
  list<Integer> criticalPath;
  list<tuple<Real,list<Integer>>> rest;
algorithm
  oLongestPathIndex := matchcontinue(iCriticalPaths, iListIdx, iLongestPath, iLongestPathIndex)
    case((cpCost, criticalPath)::rest,_,_,_)
      equation
        true = realGt(cpCost, iLongestPath);
      then getCriticalPath2(rest, iListIdx+1, cpCost, iListIdx);
    case((cpCost, criticalPath)::rest,_,_,_)
      then getCriticalPath2(rest, iListIdx+1, iLongestPath, iLongestPathIndex);
    else iLongestPathIndex;
  end matchcontinue;
end getCriticalPath2;

protected function addUpExeCostsForNode "function addUpExeCostsForNode
  author: marcusw
  This function adds up all execution costs of the given component list (iNodeComps)."
  input list<Integer> iNodeComps;
  input array<tuple<Integer,Real>> iExeCosts;
  input Real iExeCost;
  output Real oExeCost;
protected
  Integer head;
  list<Integer> rest;
  Real cost;
algorithm
  oExeCost := match(iNodeComps, iExeCosts, iExeCost)
    case(head::rest,_,_)
      equation
        ((_,cost)) = arrayGet(iExeCosts, head);
        cost = realAdd(cost, iExeCost);
        cost = addUpExeCostsForNode(rest, iExeCosts, cost);
      then cost;
    else iExeCost;
  end match;
end addUpExeCostsForNode;

protected function gatherParallelSets " gathers all nodes of the same level in a list
author: Waurich TUD 2013-07"
  input array<tuple<Integer,Real,Integer>> nodeInfo;
  output list<list<Integer>> parallelSetsOut;
protected
  Integer numLevels;
algorithm
  numLevels := Array.fold(nodeInfo,numberOfLevels,0);
  parallelSetsOut := List.fold1(List.intRange(arrayLength(nodeInfo)),gatherParallelSets1,nodeInfo,List.fill({},numLevels));
end gatherParallelSets;

protected function numberOfLevels " gets the number of values
author: Waurich TUD 2013-07"
  input tuple<Integer,Real,Integer> nodeInfoEntry;
  input Integer numLevelsIn;
  output Integer numLevelsOut;
protected
  Integer levelIn;
algorithm
  (levelIn,_,_) := nodeInfoEntry;
  numLevelsOut := intMax(levelIn,numLevelsIn);
end numberOfLevels;

protected function gatherParallelSets1 " folding function for gatherParallelSets
author: Waurich TUD 2013-07"
  input Integer idx;
  input array<tuple<Integer,Real,Integer>> nodeInfo;
  input list<list<Integer>> parallelSetIn;
  output list<list<Integer>> parallelSetOut;
protected
  Integer level;
  list<Integer> pSet;
algorithm
  ((level,_,_)) := arrayGet(nodeInfo,idx);
  pSet := listGet(parallelSetIn,level);
  pSet := idx :: pSet;
  parallelSetOut := List.replaceAt(pSet, level, parallelSetIn);
end gatherParallelSets1;

protected function getCostsForNode " function to compute the costs for the next node (including the execution costs and the communication costs).
the given nodeIndeces are from the current graph and will be transformed to original indeces via inComps by this function
author:Waurich TUD 2013-07"
  input Integer parentNode;
  input Integer childNode;
  input array<list<Integer>> inComps;
  input array<tuple<Integer,Real>> exeCosts;
  input array<Communications> commCosts;
  output Real costsOut;
algorithm
  costsOut := matchcontinue(parentNode,childNode,inComps,exeCosts,commCosts)
    local
      Real costs;
      Real commCost;
      Integer primalChild;
      Integer primalParent;
      list<Integer> primalChildLst;
      list<Integer> primalParentLst;
      list<tuple<Integer,Integer,Integer>> edgeCostLst;
    case(0,_,_,_,_)
      equation
        // the root node is not contracted
        primalChildLst = arrayGet(inComps,childNode);
        true = listLength(primalChildLst) == 1;
        primalChild = listGet(primalChildLst,1);
        ((_,costs)) = arrayGet(exeCosts,primalChild);
      then
        costs;
    case(0,_,_,_,_)
      equation
        // the root node is contracted
        primalChildLst = arrayGet(inComps,childNode);
        true = listLength(primalChildLst) > 1;
        _ = listGet(primalChildLst,1);
        costs = getCostsForContractedNodes(primalChildLst,exeCosts);
      then
        costs;
    case(_,_,_,_,_)
      equation
        // the childNode is not contracted
        primalChildLst = arrayGet(inComps,childNode);
        primalParentLst = arrayGet(inComps,parentNode);
        true = listLength(primalChildLst) == 1;
        primalChild = listGet(primalChildLst,1);
        primalParent = listGet(primalParentLst,1);
        ((_,costs)) = arrayGet(exeCosts,primalChild);
        COMMUNICATION(requiredTime=commCost) = getCommunicationCost(primalChild, primalParent ,commCosts);
        costs = costs + commCost;
      then
        costs;
    case(_,_,_,_,_)
      equation
        // the childNode is contracted
        primalChildLst = arrayGet(inComps,childNode);
        _ = arrayGet(inComps,parentNode);
        true = listLength(primalChildLst) > 1;
        costs = getCostsForContractedNodes(primalChildLst,exeCosts);
      then
        costs;
    else
      equation
        print("getCostsForNode failed! \n");
      then
        fail();
  end matchcontinue;
end getCostsForNode;

public function getCostsForContractedNodes "sums up alle execution costs for a contracted node.
authro:Waurich TUD 2013-10"
  input list<Integer> nodeList;
  input array<tuple<Integer,Real>> exeCosts;
  output Real costsOut;
algorithm
  costsOut := List.fold1(nodeList,getCostsForContractedNodes1,exeCosts,0.0);
end getCostsForContractedNodes;

protected function getCostsForContractedNodes1 "gets exeCosts for one node and add it to the foldType.
author:Waurich TUD 2013-10"
  input Integer node;
  input array<tuple<Integer,Real>> exeCosts;
  input Real costsIn;
  output Real costsOut;
protected
  Real exeCost;
algorithm
  ((_,exeCost)) := arrayGet(exeCosts,node);
  costsOut := realAdd(costsIn,exeCost);
end getCostsForContractedNodes1;

protected function getNodeCoords " computes the location of the nodes in the .graphml  with regard to the parallel sets
author:Waurich TUD 2013-07"
  input list<list<Integer>> parallelSets;
  input TaskGraph graphIn;
  output array<tuple<Integer,Integer>> nodeCoordsOut;
protected
  array<tuple<Integer,Integer>> nodeCoords;
  Integer size;
algorithm
  size := arrayLength(graphIn);
  nodeCoords := arrayCreate(size,((0,0)));
  nodeCoords := List.fold1(List.intRange(size),getYCoordForNode,parallelSets,nodeCoords);
  nodeCoordsOut := nodeCoords;
  //print("nodeCoords"+stringDelimitList(List.map(arrayList(nodeCoords),tupleToString),",")+"\n");
end getNodeCoords;

protected function getYCoordForNode "fold function to compute the y-coordinate for the graph.author: Waurich TUD 2013-07"
  input Integer compIdx;
  input list<list<Integer>> parallelSets;
  input array<tuple<Integer,Integer>> nodeCoordsIn;
  output array<tuple<Integer,Integer>> nodeCoordsOut;
protected
  Integer parallelSetIdx;
  Integer xCoord;
  Integer yCoord;
  Integer levelInterval;
  tuple<Integer,Integer> coords;
algorithm
  //levelInterval := 80;
  parallelSetIdx := getParallelSetForComp(compIdx,1,parallelSets);
  ((xCoord,yCoord)) := arrayGet(nodeCoordsIn,compIdx);
  //coords := ((xCoord,parallelSetIdx*levelInterval));
  coords := ((xCoord,parallelSetIdx));
  nodeCoordsOut := arrayUpdate(nodeCoordsIn,compIdx,coords);
end getYCoordForNode;

protected function getParallelSetForComp " find the parallelSet the inComp belongs to.
author: Waurich TUD 2013-07"
  input Integer compIn;
  input Integer setIdx;
  input list<list<Integer>> parallelSets;
  output Integer parallelSetOut;
algorithm
  parallelSetOut := matchcontinue(compIn,setIdx,parallelSets)
    local
      list<Integer> parallelSet;
      Integer parallelSetTmp;
    case(_,_,_)
      equation
        true = setIdx <= listLength(parallelSets);
        parallelSet = listGet(parallelSets,setIdx);
        //print("is "+intString(compIn)+" member of set "+intString(setIdx)+" with the nodes "+stringDelimitList(List.map(parallelSet,intString),",")+"\n");
        true = List.isMemberOnTrue(compIn,parallelSet,intEq);
        //print("true \n");
      then
        setIdx;
    case(_,_,_)
      equation
        true = setIdx <= listLength(parallelSets);
        parallelSet = listGet(parallelSets,setIdx);
        //print("is "+intString(compIn)+" member of set "+intString(setIdx)+" with the nodes "+stringDelimitList(List.map(parallelSet,intString),",")+"\n");
        false = List.isMemberOnTrue(compIn,parallelSet,intEq);
        //print("false \n");
        parallelSetTmp = getParallelSetForComp(compIn,setIdx+1,parallelSets);
      then
        parallelSetTmp;
    else
      equation
        print("getParallelSetForComp failed!\n");
      then
        fail();
  end matchcontinue;
end getParallelSetForComp;

protected function setLevelInNodeMark " sets the parallelSetIndex as a nodeMark.
author:wauricht TUD 2013-07"
  input Integer nodeIdx;
  input array<list<Integer>> inComps;
  input array<tuple<Integer,Integer>> nodeCoords;
  input array<Integer> nodeMarkIn;
  output array<Integer> nodeMarkOut;
algorithm
  nodeMarkOut := matchcontinue(nodeIdx,inComps,nodeCoords,nodeMarkIn)
    local
      array<Integer> nodeMarkTmp;
      list<Integer> components;
      Integer primalComp;
      Integer nodeMarkEntry;
      Integer yCoord;
    case(_,_,_,_)
      equation
        nodeMarkEntry = arrayGet(nodeMarkIn,nodeIdx);
        components = arrayGet(inComps,nodeIdx);
        primalComp = List.last(components);
        nodeMarkEntry = arrayGet(nodeMarkIn,primalComp);
        true = intEq(-1,nodeMarkEntry);
      then
        nodeMarkIn;
    case(_,_,_,_)
      equation
        nodeMarkEntry = arrayGet(nodeMarkIn,nodeIdx);
        components = arrayGet(inComps,nodeIdx);
        primalComp = List.last(components);
        nodeMarkEntry = arrayGet(nodeMarkIn,primalComp);
        false = intEq(-1,nodeMarkEntry);
        ((_,yCoord)) = arrayGet(nodeCoords,nodeIdx);
        nodeMarkTmp = arrayUpdate(nodeMarkIn,primalComp,yCoord);
      then
        nodeMarkTmp;
  end matchcontinue;
end setLevelInNodeMark;

protected function tupleToStringIntRealInt "author: Waurich TUD 2013-07
  Returns the given tuple as string."
  input tuple<Integer,Real,Integer> inTuple;
  output String result;
algorithm
  result := match(inTuple)
    local
      Integer int1,int2;
      Real real1;
    case((int1,real1,int2))
    then ("(" + intString(int1) + "," + realString(real1) +" , "+ intString(int2) + ")");
  end match;
end tupleToStringIntRealInt;

public function transposeCommCosts "author: marcusw
  Returns the given communication costs as transposed version."
  input array<Communications> iCommCosts;
  output array<Communications> oCommCosts;
protected
  array<Communications> tmpCommCosts;
algorithm
  tmpCommCosts := arrayCreate(arrayLength(iCommCosts), {});
  ((_,tmpCommCosts)) := Array.fold(iCommCosts, transposeCommCosts0, (1,tmpCommCosts));
  oCommCosts := tmpCommCosts;
end transposeCommCosts;

protected function transposeCommCosts0 "author: marcusw
  Helper function for transposeCommCosts."
  input Communications iCosts; //costs for all edges from <%parentComp%> to children
  input tuple<Integer,array<Communications>> iCommCosts; //<parentCompIdx, commCosts>
  output tuple<Integer,array<Communications>> oCommCosts;
protected
  Integer iParentCompIdx;
  array<Communications> tmpCommCosts;
algorithm
  (iParentCompIdx, tmpCommCosts) := iCommCosts;
  tmpCommCosts := List.fold1(iCosts, transposeCommCosts1, iParentCompIdx, tmpCommCosts);
  oCommCosts := (iParentCompIdx+1, tmpCommCosts);
end transposeCommCosts0;

protected function transposeCommCosts1 "author: marcusw
  Helper function for transposeCommCosts0."
  input Communication iCost;
  input Integer iParentCompIdx;
  input array<Communications> iCommCosts;
  output array<Communications> oCommCosts;
protected
  array<Communications> tmpCommCosts;
  Communications costs;
  Integer numberOfVars,nodeIdx;
  list<Integer> integerVars,floatVars,booleanVars,stringVars;
  Real requiredTime;
algorithm
  oCommCosts := matchcontinue(iCost, iParentCompIdx, iCommCosts)
    case(COMMUNICATION(numberOfVars=numberOfVars,integerVars=integerVars,floatVars=floatVars,booleanVars=booleanVars,stringVars=stringVars,childNode=nodeIdx,requiredTime=requiredTime),_,_)
      equation
        true = intLe(nodeIdx, arrayLength(iCommCosts));
        costs = arrayGet(iCommCosts, nodeIdx);
        costs = COMMUNICATION(numberOfVars,integerVars,floatVars,booleanVars,stringVars,iParentCompIdx,requiredTime) :: costs;
        tmpCommCosts = arrayUpdate(iCommCosts, nodeIdx, costs);
      then tmpCommCosts;
    else iCommCosts;
  end matchcontinue;
end transposeCommCosts1;

//TODO: Can this be merged with getCommCostBetweenNodes?
public function getCommunicationCost " gets the communication cost for an edge from parent node to child node.
  REMARK: use the primal indeces!!!!!!
  author: waurich TUD 2013-06."
  input Integer childIdx;
  input Integer parentIdx;
  input array<Communications> commCosts;
  output Communication oComm;
protected
  Communications commRow;
  Communication commEntry;
algorithm
  //print("Try to get comm cost for edge from " + intString(parentIdx) + " to " + intString(childIdx) + "\n");
  commRow := arrayGet(commCosts,parentIdx);
  commEntry := getCommunicationByChildIdx(commRow,childIdx);
  //(_,numOfVars,cost) := commEntry;
  oComm := commEntry;
end getCommunicationCost;

protected function getCommunicationByChildIdx "author:marcusw
  Gets the communication with the given child idx out of the communications-list."
  input Communications iComms;
  input Integer iChildIdx;
  output Communication oComm;
algorithm
  oComm := matchcontinue(iComms,iChildIdx)
    local
      Integer currentCommChild;
      Communication head, tmpComm;
      Communications rest;
    case(COMMUNICATION(childNode=currentCommChild)::rest,_)
      equation
        false = intEq(currentCommChild,iChildIdx);
        tmpComm = getCommunicationByChildIdx(rest,iChildIdx);
      then tmpComm;
    case((head as COMMUNICATION(childNode=currentCommChild))::_,_)
      equation
        true = intEq(currentCommChild,iChildIdx);
      then head;
    case({},_)
      equation
        print("getCommunicationByChildIdx failed! - the child idx "+intString(iChildIdx)+" can not be found in the list of edges\n");
      then
        fail();
  end matchcontinue;
end getCommunicationByChildIdx;

public function getCommCostTimeBetweenNodes"author: waurich TUD 2014-05
  Get the required time of the highest communication costs between the given nodes."
  input Integer iParentNodeIdx;
  input Integer iChildNodeIdx;
  input TaskGraphMeta iTaskGraphMeta;
  output Real oCommCost;
protected
  Real requiredTime;
algorithm
  COMMUNICATION(requiredTime=requiredTime) := getCommCostBetweenNodes(iParentNodeIdx,iChildNodeIdx,iTaskGraphMeta);
  oCommCost := requiredTime;
end getCommCostTimeBetweenNodes;

public function getCommCostBetweenNodes "author: marcusw
  Get the edge with highest communication costs between the given nodes."
  input Integer iParentNodeIdx;
  input Integer iChildNodeIdx;
  input TaskGraphMeta iTaskGraphMeta;
  output Communication oCommCost;
protected
  list<Integer> childComps, parentComps;
  array<list<Integer>> inComps;
  array<Communications> commCosts;
  list<Option<Communication>> concreteCommCostsOpt;
  Communications concreteCommCosts;
algorithm
  TASKGRAPHMETA(inComps=inComps,commCosts=commCosts) := iTaskGraphMeta;
  parentComps := arrayGet(inComps, iParentNodeIdx);
  childComps := arrayGet(inComps, iChildNodeIdx);
  concreteCommCostsOpt := List.map2(parentComps, getCommCostBetweenNodes0, childComps, commCosts);
  concreteCommCosts := List.flatten(List.map(concreteCommCostsOpt, List.fromOption));
  oCommCost := getHighestCommCost(concreteCommCosts, COMMUNICATION(0,{},{},{},{},-1,-1.0));
end getCommCostBetweenNodes;

protected function getCommCostBetweenNodes0
  input Integer iParentComp;
  input list<Integer> iChildComps;
  input array<Communications> iCommCosts;
  output Option<Communication> oHighestComm; //the communication with the highest costs
protected
  Communications commCosts, filteredCommCosts;
  Communication highestCommCost;
algorithm
  oHighestComm := matchcontinue(iParentComp, iChildComps, iCommCosts)
    case(_,_,_)
      equation
        commCosts = arrayGet(iCommCosts, iParentComp);
        filteredCommCosts = List.filter1OnTrue(commCosts, getCommCostBetweenNodes1, iChildComps);
        true = List.isNotEmpty(filteredCommCosts);
        highestCommCost = getHighestCommCost(filteredCommCosts, COMMUNICATION(0,{},{},{},{},-1,-1.0));
      then SOME(highestCommCost);
    else NONE();
  end matchcontinue;
end getCommCostBetweenNodes0;

protected function getCommCostBetweenNodes1 "author: marcusw
  Checks if the communication-component is part of the child component list. "
  input Communication iCommCost;
  input list<Integer> iChildComps;
  output Boolean oResult;
protected
  Integer compIdx;
algorithm
  COMMUNICATION(childNode=compIdx) := iCommCost;
  oResult := List.exist1(iChildComps, intEq, compIdx);
end getCommCostBetweenNodes1;

protected function getHighestCommCost
  "Get the communication with highest costs out of the given list.
  author: marcusw"
  input Communications iCommCosts;
  input Communication iHighestTuple;
  output Communication oHighestTuple;
protected
  Real highestCost, currentCost;
  Communication head;
  Communications rest;
algorithm
  oHighestTuple := matchcontinue(iCommCosts, iHighestTuple)
    case((head as COMMUNICATION(requiredTime=currentCost))::rest, COMMUNICATION(requiredTime=highestCost))
      equation
        true = realGt(currentCost, highestCost);
      then getHighestCommCost(rest, head);
    case(head::rest,_)
      then getHighestCommCost(rest, iHighestTuple);
    else iHighestTuple;
  end matchcontinue;
end getHighestCommCost;

public function sumUpExeCosts"accumulates the execution costs of all tasks in the graph.
author:Waurich TUD 2014-07"
  input TaskGraph iGraph;
  input TaskGraphMeta iMeta;
  output tuple<Integer,Real> execCosts;
protected
  Integer cost1;
  Real cost2;
  list<Integer> comps;
  array<list<Integer>> inComps;
  tuple<Integer,Real> costs;
  array<tuple<Integer,Real>> exeCosts;
  list<tuple<Integer,Real>> exeCostLst;
algorithm
  execCosts := match(iGraph,iMeta)
    case(_,TASKGRAPHMETA(inComps=inComps, exeCosts=exeCosts))
      equation
        comps = List.flatten(List.map1(List.intRange(arrayLength(iGraph)),Array.getIndexFirst,inComps));
        exeCostLst = List.map1(comps,Array.getIndexFirst,exeCosts);
        cost1 = List.fold(List.map(exeCostLst,Util.tuple21),intAdd,0);
        cost2 = List.fold(List.map(exeCostLst,Util.tuple22),realAdd,0.0);
      then ((cost1,cost2));
    else ((0,0.0));
  end match;
end sumUpExeCosts;

public function getAllSCCsOfGraph
  "Get all SCC-indices that are part of the graph.
  author: marcusw"
  input TaskGraphMeta iTaskGraphMeta;
  output list<Integer> oSccs;
protected
  Integer taskIdx, mark;
  array<list<Integer>> inComps;
  list<Integer> comps;
  array<Integer> nodeMark;
  list<Integer> tmpSccs;
algorithm
  tmpSccs := {};
  TASKGRAPHMETA(inComps=inComps, nodeMark=nodeMark) := iTaskGraphMeta;
  for taskIdx in 1:arrayLength(inComps) loop
    //print("getAllSCCsOfGraph: Try to get component mark for task " + intString(taskIdx) + " out of marks with size '" + intString(arrayLength(nodeMark)) + "'\n");
    //mark := arrayGet(nodeMark, taskIdx);
    //print("getAllSCCsOfGraph: mark is '" + intString(mark) + "'\n");
    //if(intGe(mark, 0)) then
      comps := arrayGet(inComps, taskIdx);
      //print("getAllSCCsOfGraph: components are '" + stringDelimitList(List.map(comps, intString), ",") + "'\n");
      tmpSccs := listAppend(tmpSccs, comps);
    //end if;
  end for;
  oSccs := tmpSccs;
end getAllSCCsOfGraph;

//TODO: Remove
public function roundReal "rounds a real to the nth decimal
author: Waurich TUD 2014-01"
  input Real inReal;
  input Integer nIn;
  output Real outReal;
protected
  Integer int;
  Real real;
algorithm
  real := inReal * (10.0 ^ nIn);
  real := floor(real);
  outReal := real / (10.0 ^ nIn);
end roundReal;

//--------------------------------------------------------
//  Get annotations from backendDAE and display in graphML
//--------------------------------------------------------

protected function setAnnotationsForTasks"sets annotations of variables and equations for every task in the array (index: task idx)
author:Waurich TUD 2014-05 "
  input TaskGraphMeta taskGraphInfo;
  input BackendDAE.BackendDAE backendDAE;
  input array<String> annotInfoIn;
  output array<String> annotInfoOut;
protected
  BackendDAE.EqSystems systs;
algorithm
  BackendDAE.DAE(eqs=systs) := backendDAE;
  ((_,annotInfoOut)) := List.fold1(systs,setAnnotationsForTasks1,taskGraphInfo,(0,annotInfoIn));
end setAnnotationsForTasks;

protected function setAnnotationsForTasks1"sets annotations for a task of vars and equations of an equationsystem
author: Waurich TUD 2014-05"
  input BackendDAE.EqSystem syst;
  input TaskGraphMeta taskGraphInfo;
  input tuple<Integer,array<String>> infoIn;
  output tuple<Integer,array<String>> infoOut;
protected
  Integer idx;
  array<String> annots;
  BackendDAE.Variables vars;
  BackendDAE.EquationArray eqs;
algorithm
  (idx,annots) := infoIn;
  BackendDAE.EQSYSTEM(orderedVars=vars,orderedEqs=eqs) := syst;
  //set annotations of variables
  annots := List.fold3(List.intRange(BackendVariable.varsSize(vars)),setAnnotationsForVar,vars,taskGraphInfo,idx,annots);
  infoOut := (BackendVariable.varsSize(vars)+idx,annots);
end setAnnotationsForTasks1;

protected function setAnnotationsForVar"sets the annotations of a variable in the annotArray"
  input Integer backendVarIdx;
  input BackendDAE.Variables vars;
  input TaskGraphMeta taskGraphInfo;
  input Integer eqSysOffset;
  input array<String> annotInfoIn;
  output array<String> annotInfoOut;
algorithm
  annotInfoOut := matchcontinue(backendVarIdx,vars,taskGraphInfo,eqSysOffset,annotInfoIn)
    local
      Integer compIdx, taskIdx;
      String annotString;
      BackendDAE.Var var;
      DAE.ComponentRef cr;
      Option<SCode.Comment> annot;
      array<list<Integer>> inComps;
      array<tuple<Integer,Integer,Integer>> varCompMapping;
      array<tuple<Integer,Integer,Integer>> eqCompMapping;
      array<Integer> nodeMark;
    case(_,_,TASKGRAPHMETA(inComps=inComps, varCompMapping=varCompMapping, nodeMark=nodeMark),_,_)
      equation
        var = BackendVariable.getVarAt(vars,backendVarIdx);
        BackendDump.printVar(var);
        true = BackendVariable.hasAnnotation(var);
        ((compIdx,_,_)) = arrayGet(varCompMapping,backendVarIdx+eqSysOffset);
        taskIdx = getCompInComps(compIdx,1,inComps,nodeMark);
        annot = BackendVariable.getAnnotationComment(var);
        annotString = arrayGet(annotInfoIn,taskIdx);
        cr = BackendVariable.varCref(var);
        annotString = annotString + "("+ComponentReference.printComponentRefStr(cr)+": "+DAEDump.dumpCommentAnnotationStr(annot)+") ";
        arrayUpdate(annotInfoIn,taskIdx,annotString);
      then
        annotInfoIn;
    else annotInfoIn;
  end matchcontinue;
end setAnnotationsForVar;


//--------------------------------------------------------
//  Append removed equations like asserts to the DAE graph
//--------------------------------------------------------

public function appendRemovedEquations"appends to the graph (DAE-onlySCCs) all removed equations i.e. asserts...
author:Waurich TUD 2014-07"
  input BackendDAE.BackendDAE dae;
  input TaskGraph graphIn;
  input TaskGraphMeta graphDataIn;
  output TaskGraph graphOut;
  output TaskGraphMeta graphDataOut;
algorithm
  (graphOut,graphDataOut) := matchcontinue(dae,graphIn,graphDataIn)
    local
      Integer numNewComps;
      list<Integer> newComps;
      list<list<Integer>> nodeLst;
      list<list<tuple<Integer,Integer>>> nodeVarLst;
      array<tuple<Integer,Integer,Integer>> varCompMap;
      TaskGraph graph;
      TaskGraphMeta graphData;
      BackendDAE.EquationArray remEqs;
      BackendDAE.Shared shared;
      list<BackendDAE.Equation> eqLst;
      list<list<DAE.ComponentRef>> crefsLst;
      list<tuple<Integer,Integer>> tplLst;
      array<list<Integer>> inComps1,inComps2;
      array<tuple<Integer,Integer,Integer>> varCompMapping1;
      array<tuple<Integer,Integer,Integer>> eqCompMapping1;
      array<list<Integer>> compParamMapping1;
      array<String> compNames1,compNames2;
      array<String> compDescs1,compDescs2;
      array<tuple<Integer,Real>> exeCosts1,exeCosts2;
      array<Communications> commCosts1;
      array<Integer> nodeMark1,nodeMark2;
      array<ComponentInfo> compInformations1, compInformations2;
  case(_,_,_)
    equation
      BackendDAE.DAE(shared = shared) = dae;
      BackendDAE.SHARED(removedEqs=remEqs) = shared;
      TASKGRAPHMETA(varCompMapping=varCompMap) = graphDataIn;
      eqLst = BackendEquation.equationList(remEqs);
      numNewComps = listLength(eqLst);
      true = intNe(numNewComps,0);
      crefsLst = List.map(eqLst,BackendEquation.equationCrefs);
      //print("crefs \n");List.map_0(crefsLst,ComponentReference.printComponentRefList);
      nodeVarLst = List.map2(crefsLst,getNodeForCrefLst,dae,varCompMap);
      //print("nodeVarLst"+stringDelimitList(List.map(nodeVarLst,printNodeVars),"\n")+"\n");

      TASKGRAPHMETA(inComps=inComps1, varCompMapping=varCompMapping1, eqCompMapping=eqCompMapping1, compParamMapping=compParamMapping1, compNames=compNames1, compDescs=compDescs1, exeCosts=exeCosts1, commCosts=commCosts1, nodeMark=nodeMark1, compInformations=compInformations1) = graphDataIn;
      graph = arrayAppend(graphIn,arrayCreate(numNewComps,{}));
      newComps = List.intRange2(arrayLength(graphIn)+1,arrayLength(graphIn)+numNewComps);
      //print("newComps: "+stringDelimitList(List.map(newComps,intString)," | ")+"\n");
      graph =  List.threadFold(nodeVarLst,newComps,addEdgesToGraph,graph);

      inComps2 = listArray(List.map(newComps,List.create));
      compNames2 = arrayCreate(numNewComps,"assert");
      compDescs2 = listArray(List.map(eqLst,BackendDump.equationString));
      nodeMark2 = arrayCreate(numNewComps,-2);
      exeCosts2 = listArray(List.map1(eqLst,estimateEquationCosts,shared));
      compInformations2 = arrayCreate(numNewComps, COMPONENTINFO(false, false, true));
      inComps1 = arrayAppend(inComps1,inComps2);
      compNames1 = arrayAppend(compNames1,compNames2);
      compDescs1 = arrayAppend(compDescs1,compDescs2);
      nodeMark1 = arrayAppend(nodeMark1,nodeMark2);
      exeCosts1 = arrayAppend(exeCosts1,exeCosts2);
      compInformations1 = arrayAppend(compInformations1, compInformations2);
      commCosts1 = List.threadFold1(nodeVarLst,newComps,setCommCostsToParent,74.0,commCosts1);
      graphData = TASKGRAPHMETA(inComps1,varCompMapping1,eqCompMapping1,compParamMapping1,compNames1,compDescs1,exeCosts1,commCosts1,nodeMark1,compInformations1);
    then (graph,graphData);
  else (graphIn,graphDataIn);
  end matchcontinue;
end appendRemovedEquations;

protected function estimateEquationCosts"estimates costs for equations.
author: Waurich TUD 2015-04"
  input BackendDAE.Equation eqIn;
  input BackendDAE.Shared sharedIn;
  output tuple<Integer,Real> tplOut; //<Operations,Costs>
protected
  Integer  numAdd,numMul,numDiv,numTrig,numRel,numOth, numFuncs, numLog;
  BackendDAE.CompInfo compInfo;
algorithm
  (_,(numAdd,numMul,numDiv,numTrig,numRel,numLog,numOth,numFuncs)) := BackendEquation.traverseExpsOfEquation(eqIn,function BackendDAEOptimize.countOperationsExp(shared=sharedIn),(0,0,0,0,0,0,0,0));
  compInfo := BackendDAE.NO_COMP(numAdd,numMul,numDiv,numTrig,numRel,numLog,numOth,numFuncs);
  tplOut := calculateCosts(compInfo);
end estimateEquationCosts;

protected function printNodeVars
  input list<tuple<Integer,Integer>> nodes;
  output String s;
algorithm
  s := ":" + stringDelimitList(List.map(nodes,printNodeVars1)," | ");
end printNodeVars;

protected function printNodeVars1
  input tuple<Integer,Integer> node;
  output String s;
algorithm
  s := "("+intString(Util.tuple21(node))+","+intString(Util.tuple22(node))+")";
end printNodeVars1;

protected function setCommCostsToParent"sets/updated the communication costs for the list of parents to the child node.
author:Waurich TUD 2014-07"
  input list<tuple<Integer,Integer>> parents; //<parentNodeIdx,varIdx>
  input Integer child;
  input Real reqCycles;
  input array<Communications> commCostsIn;
  output array<Communications> commCostsOut;
algorithm
  commCostsOut := List.fold2(parents,setCommCosts,child,reqCycles,commCostsIn);
end setCommCostsToParent;

protected function setCommCosts"sets/updated the communication costs for the edge from parent to child node.
author:Waurich TUD 2014-07"
  input tuple<Integer,Integer> parent; //<parentNodeIdx,varIdx>
  input Integer child;
  input Real reqCycles;
  input array<Communications> commCostsIn;
  output array<Communications> commCostsOut;
protected
  Communications row;
  Integer parentNodeIdx, varIdx;
algorithm
  (parentNodeIdx,varIdx) := parent;
  row := arrayGet(commCostsIn,parentNodeIdx);
  row := List.filter1OnTrue(row,isCommunicationChildEqualToIdx,child);
  row := COMMUNICATION(1,{},{varIdx},{},{},child,reqCycles)::row;
  commCostsOut := arrayUpdate(commCostsIn,parentNodeIdx,row);
end setCommCosts;

protected function isCommunicationChildEqualToIdx "author:marcusw
  Returns true if the child, stored in the iComm-object, is equals to the iIdx."
  input Communication iComm;
  input Integer iIdx;
  output Boolean isEq;
protected
  Integer childNode;
algorithm
  COMMUNICATION(childNode=childNode) := iComm;
  isEq := intNe(childNode,iIdx);
end isCommunicationChildEqualToIdx;

protected function addEdgesToGraph"adds several edges from the list of parent to child to the taskgraph
author:Waurich TUD 2014-07"
  input list<tuple<Integer,Integer>> parents; //<nodeIdx, varIdx>
  input Integer child;
  input TaskGraph graphIn;
  output TaskGraph graphOut;
algorithm
  graphOut := List.fold1(List.map(parents,Util.tuple21),addEdgeToGraph,child,graphIn);
end addEdgesToGraph;

protected function addEdgeToGraph"adds an edge from parent to child to the taskgraph
author:Waurich TUD 2014-07"
  input Integer parent;
  input Integer child;
  input TaskGraph graphIn;
  output TaskGraph graphOut;
protected
  list<Integer> row;
algorithm
  row := arrayGet(graphIn,parent);
  row := List.unique(child::row);
  graphOut := arrayUpdate(graphIn,parent,row);
end addEdgeToGraph;

protected function getNodeForCrefLst"gets the node in which the var for the given cref is solved.
author:Waurich TUD 2014-07"
  input list<DAE.ComponentRef> iCrefs;
  input BackendDAE.BackendDAE iDae;
  input array<tuple<Integer,Integer,Integer>> iVarCompMap;
  output list<tuple<Integer,Integer>> oNodeVarLst; //<nodeIdx, varIdx>
protected
  list<tuple<Integer,Integer>> tmpNodeVarLst;
algorithm
  tmpNodeVarLst := List.map2(iCrefs,getNodeForCref,iDae,iVarCompMap);
  oNodeVarLst := List.filterOnTrue(tmpNodeVarLst,nodeIsDependent);
  //print("tmpNodeVarLst1 "+printNodeVars(tmpNodeVarLst)+"\n");
end getNodeForCrefLst;

protected function nodeIsDependent
  "if this node has no parent, it is independent
   author: waurich"
  input tuple<Integer,Integer> node;
  output Boolean dep;
protected
  Integer tpl1;
algorithm
  (tpl1,_) := node;
  dep := intNe(tpl1,-1);
end nodeIsDependent;

protected function getNodeForCref "get the node- and var-idx for the given cref
author:Waurich TUD 2014-07"
  input DAE.ComponentRef iCref;
  input BackendDAE.BackendDAE iDae;
  input array<tuple<Integer,Integer,Integer>> iVarCompMapping;
  output tuple<Integer,Integer> oNodeVarIdx; //<nodeIdx, varIdx>
protected
  Integer eqSysIdx,varIdx,nodeIdx;
  BackendDAE.EqSystems eqSystems;
algorithm
  BackendDAE.DAE(eqs=eqSystems) := iDae;
  (eqSysIdx,varIdx,_) := getNodeForCref1(eqSystems,iCref,1);
  //print("got var "+intString(varIdx)+" in eqSys "+intString(eqSysIdx)+"\n");
  nodeIdx := getNodeForVarIdx(varIdx,eqSysIdx,iVarCompMapping,varIdx);
  //print("got nodeIdx "+intString(nodeIdx)+"\n");
  oNodeVarIdx := (nodeIdx,varIdx);
end getNodeForCref;

protected function getNodeForCref1
  input BackendDAE.EqSystems eqSystems;
  input DAE.ComponentRef cref;
  input Integer eqSysIdxIn;
  output Integer eqSysIdx;
  output Integer varIdx;
  output Boolean found;
algorithm
  (eqSysIdx,varIdx,found) := matchcontinue(eqSystems,cref,eqSysIdxIn)
    local
      Boolean b;
      Integer var,esIdx,vIdx;
      list<Integer> lst;
      BackendDAE.EqSystems eqSys;
      BackendDAE.EqSystems rest;
      BackendDAE.Variables vars;
      list<BackendDAE.Var> varLst;
   case(BackendDAE.EQSYSTEM(orderedVars = vars)::_,_,_)
      equation
        //print("check cref: "+ComponentReference.printComponentRefStr(cref)+"\n");
        (varLst,lst) = BackendVariable.getVar(cref,vars);
        if intNe(listLength(lst),1) then
          print("Check if there is a assert or something that is dependent of arrayEquations");
        end if;
        if BackendVariable.isStateVar(List.first(varLst)) then // if its dependent on a state --> no edge in the task graph
          (esIdx,vIdx,b) = (-1,-1,false);
        else
          (esIdx,vIdx,b) = (eqSysIdxIn,List.first(lst),true);
        end if;
      then (esIdx,vIdx,b);
    case(BackendDAE.EQSYSTEM()::rest,_,_)
      equation
        (esIdx,vIdx,b) = getNodeForCref1(rest,cref,eqSysIdxIn+1);
      then (esIdx,vIdx,b);
    case({},_,_)
      then (-1,-1,false);
  end matchcontinue;
end getNodeForCref1;

protected function getNodeForVarIdx
  input Integer varIdx;
  input Integer eqSysIdx;
  input array<tuple<Integer,Integer,Integer>> varCompMapping;
  input Integer tryThisIndex;
  output Integer nodeIdxOut;
algorithm
  nodeIdxOut := matchcontinue(varIdx,eqSysIdx,varCompMapping,tryThisIndex)
    local
      Integer offset,eqSys,node;
      Boolean eqSysNeq;
  case(_,_,_,_)
    equation
      ((node,eqSys,offset)) = arrayGet(varCompMapping,tryThisIndex);
      eqSysNeq = intNe(eqSys,eqSysIdx);
      node = if eqSysNeq then getNodeForVarIdx(varIdx,eqSysIdx,varCompMapping,tryThisIndex+offset) else node;
    then node;
  case(-1,-1,_,_)
    then -1;
  end matchcontinue;
end getNodeForVarIdx;

//-------------------------
// dump visualization xml
//-------------------------

public function visualizationInfoXML"dumps an xml containing information about visualization objects.
author:Waurich TUD 2015-04"
  input BackendDAE.BackendDAE daeIn;
  input String fileName;
protected
  BackendDAE.EqSystems eqs;
  BackendDAE.Shared shared;
  BackendDAE.Variables knownVars, aliasVars;
  list<BackendDAE.Var> knownVarLst, allVarLst, aliasVarLst;
  list<GraphML.Visualization> visuals;
  list<GraphML.VisualizationTPL> visualsTPL;
  list<String> allVisuals;
algorithm
  BackendDAE.DAE(eqs=eqs, shared=shared) := daeIn;
  BackendDAE.SHARED(knownVars=knownVars,aliasVars=aliasVars) := shared;
  //get all variables that contain visualization vars
  knownVarLst := BackendVariable.varList(knownVars);
  aliasVarLst := BackendVariable.varList(aliasVars);
  allVarLst := List.flatten(List.map(List.map(eqs, BackendVariable.daeVars),BackendVariable.varList));

  //collect all visualization objects
  (knownVarLst,allVisuals) := List.fold(knownVarLst,isVisualizationVar,({},{}));
    //print("ALL VISUALS "+stringDelimitList(allVisuals," |")+"\n");
  (allVarLst,_) := List.fold(allVarLst,isVisualizationVar,({},{}));
  (aliasVarLst,_) := List.fold(aliasVarLst,isVisualizationVar,({},{}));

  //fill theses visualization objects with information
  allVarLst := listAppend(listAppend(knownVarLst,allVarLst),aliasVarLst);
  (visuals,_) := List.mapFold(allVisuals, fillVisualizationObjects,allVarLst);
  //print("\nvisuals :\n"+stringDelimitList(List.map(visuals,printViusalization),"\n")+"\n");

  //convert to template type and dump
  visualsTPL := List.map(visuals,convertToTPLvis);
  GraphML.dumpVis(listArray(visualsTPL), fileName+"_visual.xml");
end visualizationInfoXML;

protected function convertToTPLvis"converts the visualization object to a VisualizationTPL.
author:Waurich TUD 2015-04"
  input GraphML.Visualization visIn;
  output GraphML.VisualizationTPL visOut;
algorithm
  visOut := match(visIn)
    local
      String ident, shapeType, e;
      DAE.Exp  length, width, height, extra, specularCoeff;
      array<DAE.Exp> color, r, r_shape, lengthDir, widthDir;
      array<String> rTPL, colorTPL, lengthDirTPL, widthDirTPL, r_shapeTpl;
      array<list<DAE.Exp>> T;
      list<DAE.Exp> T0;
      list<String> T0tpl;
      array<list<String>> Ttpl;
  case(GraphML.SHAPE(ident, shapeType, T, r, r_shape, lengthDir, widthDir, length, width, height, extra, color, specularCoeff))
    algorithm
      rTPL := Array.map(r,ExpressionDump.printExpStr);
      r_shapeTpl := Array.map(r_shape,ExpressionDump.printExpStr);
      lengthDirTPL := Array.map(lengthDir,ExpressionDump.printExpStr);
      widthDirTPL := Array.map(widthDir,ExpressionDump.printExpStr);
      colorTPL := Array.map(color,ExpressionDump.printExpStr);
      Ttpl := arrayCreate(3,{""});
      for i in List.intRange(3) loop
        T0 := arrayGet(T,i);
        T0tpl := List.map(T0,ExpressionDump.printExpStr);
        Ttpl := arrayUpdate(Ttpl,i,T0tpl);
      end for;
    then GraphML.SHAPE_TPL(ident, shapeType, Ttpl, rTPL, r_shapeTpl, lengthDirTPL, widthDirTPL, ExpressionDump.printExpStr(length), ExpressionDump.printExpStr(width), ExpressionDump.printExpStr(height), ExpressionDump.printExpStr(extra), colorTPL,  ExpressionDump.printExpStr(specularCoeff));
  end match;
end convertToTPLvis;

protected function fillVisualizationObjects"gets the identifier of a visualization object as an input and collects all information from allVars.
author:Waurich TUD 2015-04"
  input String nameIn;
  input list<BackendDAE.Var> allVarsIn;
  output GraphML.Visualization visOut;
  output list<BackendDAE.Var> allVarsOut;
algorithm
  (visOut,allVarsOut) := matchcontinue(nameIn,allVarsIn)
    local
      String name;
      list<String> nameChars,prefix;
      GraphML.Visualization vis;
      list<BackendDAE.Var> allVars;
  case(_,_)
    algorithm
      nameChars := stringListStringChar(nameIn);
      (prefix,nameChars) := List.split(nameChars,6);
      name := stringCharListString(nameChars);
      name := Util.stringReplaceChar(name,"$",".");
      true := stringEqual(stringCharListString(prefix),"Shape$");
      vis := GraphML.SHAPE(name,"",arrayCreate(3,{DAE.RCONST(-1),DAE.RCONST(-1),DAE.RCONST(-1)}),
                           arrayCreate(3,DAE.RCONST(-1)), arrayCreate(3,DAE.RCONST(-1)), arrayCreate(3,DAE.RCONST(-1)),arrayCreate(3,DAE.RCONST(-1)),
                           DAE.RCONST(-1),DAE.RCONST(-1),DAE.RCONST(-1),DAE.RCONST(-1), arrayCreate(3,DAE.RCONST(-1)), DAE.RCONST(-1));
      (allVars,vis) := List.fold(allVarsIn,fillVisualizationObjects1,({},vis));
    then (vis,allVarsIn);
  else
    algorithm
    print("fillVisualizationObjects failed! - not yet supported type");
   then fail();
  end matchcontinue;
end fillVisualizationObjects;

protected function makeCrefQualFromString"generates a qualified cref from the '.' separated string.
author: Waurich TUD 2015-04"
  input String s;
  output DAE.ComponentRef crefOut;
protected
  list<String> sLst;
  DAE.ComponentRef cref;
  list<DAE.ComponentRef> crefs;
algorithm
  sLst := Util.stringSplitAtChar(s,".");
  crefs := List.map2(sLst,ComponentReference.makeCrefIdent,DAE.T_REAL_DEFAULT,{});
  cref::crefs := crefs;
  crefOut := List.foldr(crefs,ComponentReference.joinCrefs,cref);
end makeCrefQualFromString;

protected function splitCrefAfter"checks if crefCut exists in the crefIn and outputs the appending crefs
author:Waurich TUD 2015-04"
  input DAE.ComponentRef crefIn;
  input DAE.ComponentRef crefCut;
  output DAE.ComponentRef crefOut;
  output Boolean wasCut;
algorithm
  (crefOut,wasCut) := matchcontinue(crefIn,crefCut)
    local
      DAE.Ident ident1,ident2;
      DAE.ComponentRef crefCut1, crefIn1;
  case(DAE.CREF_QUAL(ident=ident1, componentRef=crefIn1),DAE.CREF_QUAL(ident=ident2, componentRef=crefCut1))
    equation
      // the crefs are not equal, check the next cref in crefIn
      true = not stringEq(ident1,ident2);
    then splitCrefAfter(crefIn1,crefCut);
  case(DAE.CREF_QUAL(ident=ident1, componentRef=crefIn1),DAE.CREF_QUAL(ident=ident2, componentRef=crefCut1))
    equation
      // the crefs are equal, continue checking
      true = stringEq(ident1,ident2);
    then splitCrefAfter(crefIn1,crefCut1);
  case(DAE.CREF_QUAL(ident=ident1, componentRef=crefIn1),DAE.CREF_IDENT(ident=ident2))
    equation
      // the cref has to be cut after this step
      true = stringEq(ident1,ident2);
    then (crefIn1,true);
  case(DAE.CREF_QUAL(ident=ident1, componentRef=crefIn1),DAE.CREF_IDENT(ident=ident2))
    equation
      // there is no identical cref
      true = not stringEq(ident1,ident2);
    then (crefIn1,false);
   else
     then (crefCut,false);
  end matchcontinue;
end splitCrefAfter;

protected function fillVisualizationObjects1"checks if a variable belongs to a certain visualization var. if true, add information to the visualization object
author:Waurich TUD 2015-04"
  input BackendDAE.Var varIn; //check this var
  input tuple<list<BackendDAE.Var>,GraphML.Visualization> tplIn; // fold <vars for other visualization objects, the current visualization >
  output tuple<list<BackendDAE.Var>,GraphML.Visualization> tplOut;
algorithm
   tplOut := matchcontinue(varIn,tplIn)
    local
      String ident, compIdent;
      list<BackendDAE.Var> vars;
      DAE.ComponentRef cref,crefIdent,cref0,cref1;
      GraphML.Visualization vis;
  case(BackendDAE.VAR(varName=cref),(vars, vis as GraphML.SHAPE(ident=ident)))
    algorithm
      //this var belongs to the visualization object
      crefIdent := makeCrefQualFromString(ident); // make a qualified cref out of the shape ident
      (cref1,true) := splitCrefAfter(cref,crefIdent); // check if this occures in the qualified var cref
      vis := fillShapeObject(cref1,varIn,vis);
    then (vars, vis);
  else
    algorithm
      (vars,vis) := tplIn;
    then (varIn::vars, vis);
  end matchcontinue;
end fillVisualizationObjects1;

protected function fillShapeObject"sets the visualization info in the visualization object
author:Waurich TUD 2015-04"
  input DAE.ComponentRef cref;
  input BackendDAE.Var var;
  input GraphML.Visualization visIn;
  output GraphML.Visualization visOut;
algorithm
  visOut := matchcontinue(cref,var,visIn)
    local
      Option<DAE.Exp> bind;
      DAE.Exp exp, length, width, height, extra, specularCoeff;
      String ident, shapeType, svalue;
      Integer ivalue, pos, pos1;
      Real rvalue;
      array<DAE.Exp> color, r, lengthDir, widthDir, r_shape ;
      list<DAE.Exp> T0;
      array<list<DAE.Exp>> T;
  case(DAE.CREF_IDENT(ident="shapeType"),BackendDAE.VAR(bindExp=SOME(DAE.SCONST(svalue))), GraphML.SHAPE(ident=ident, shapeType=shapeType, T=T, r=r, r_shape=r_shape, lengthDir=lengthDir, widthDir=widthDir, length=length, width=width, height=height, extra=extra, color=color, specularCoeff=specularCoeff))
    then (GraphML.SHAPE(ident, svalue, T, r, r_shape, lengthDir, widthDir, length, width, height, extra, color, specularCoeff));

  case(DAE.CREF_QUAL(ident="R",componentRef=DAE.CREF_IDENT(ident="T", subscriptLst = {DAE.INDEX(DAE.ICONST(pos)),DAE.INDEX(DAE.ICONST(pos1))})),BackendDAE.VAR(bindExp=bind), GraphML.SHAPE(ident=ident, shapeType=shapeType, T=T, r=r, r_shape=r_shape, lengthDir=lengthDir, widthDir=widthDir, length=length, width=width, height=height, extra=extra, color=color, specularCoeff=specularCoeff))
    algorithm
      if Util.isSome(bind) then exp := Util.getOption(bind);
      else exp := BackendVariable.varExp(var);
      end if;
      T0 := arrayGet(T,pos);
      T0 := List.replaceAt(exp,pos1,T0);
      T := arrayUpdate(T,pos,T0);
    then (GraphML.SHAPE(ident, shapeType, T, r, r_shape, lengthDir, widthDir, length, width, height, extra, color, specularCoeff));

  case(DAE.CREF_IDENT(ident="r", subscriptLst = {DAE.INDEX(DAE.ICONST(pos))}),BackendDAE.VAR(bindExp=bind), GraphML.SHAPE(ident=ident, shapeType=shapeType, T=T, r=r, r_shape=r_shape, lengthDir=lengthDir, widthDir=widthDir, length=length, width=width, height=height, extra=extra, color=color, specularCoeff=specularCoeff))
    algorithm
      if Util.isSome(bind) then exp := Util.getOption(bind);
      else exp := BackendVariable.varExp(var);
      end if;
      r := arrayUpdate(r,pos,exp);
    then (GraphML.SHAPE(ident, shapeType, T, r, r_shape, lengthDir, widthDir, length, width, height, extra, color, specularCoeff));

  case(DAE.CREF_IDENT(ident="r_shape", subscriptLst = {DAE.INDEX(DAE.ICONST(pos))}),BackendDAE.VAR(bindExp=bind), GraphML.SHAPE(ident=ident, shapeType=shapeType, T=T, r=r, r_shape=r_shape, lengthDir=lengthDir, widthDir=widthDir, length=length, width=width, height=height, extra=extra, color=color, specularCoeff=specularCoeff))
    algorithm
      if Util.isSome(bind) then exp := Util.getOption(bind);
      else exp := BackendVariable.varExp(var);
      end if;
      r_shape := arrayUpdate(r_shape,pos,exp);
    then (GraphML.SHAPE(ident, shapeType, T, r, r_shape, lengthDir, widthDir, length, width, height, extra, color, specularCoeff));

  case(DAE.CREF_IDENT(ident="lengthDirection", subscriptLst = {DAE.INDEX(DAE.ICONST(pos))}),BackendDAE.VAR(bindExp=bind), GraphML.SHAPE(ident=ident, shapeType=shapeType, T=T, r=r, r_shape=r_shape, lengthDir=lengthDir, widthDir=widthDir, length=length, width=width, height=height, extra=extra, color=color, specularCoeff=specularCoeff))
    algorithm
      if Util.isSome(bind) then exp := Util.getOption(bind);
      else exp := BackendVariable.varExp(var);
      end if;
      lengthDir := arrayUpdate(lengthDir,pos,exp);
    then (GraphML.SHAPE(ident, shapeType, T, r, r_shape, lengthDir, widthDir, length, width, height, extra, color, specularCoeff));

  case(DAE.CREF_IDENT(ident="widthDirection", subscriptLst = {DAE.INDEX(DAE.ICONST(pos))}),BackendDAE.VAR(bindExp=bind), GraphML.SHAPE(ident=ident, shapeType=shapeType, T=T, r=r, r_shape=r_shape, lengthDir=lengthDir, widthDir=widthDir, length=length, width=width, height=height, extra=extra, color=color, specularCoeff=specularCoeff))
    algorithm
      if Util.isSome(bind) then exp := Util.getOption(bind);
      else exp := BackendVariable.varExp(var);
      end if;
      widthDir := arrayUpdate(widthDir,pos,exp);
    then (GraphML.SHAPE(ident, shapeType, T, r, r_shape, lengthDir, widthDir, length, width, height, extra, color, specularCoeff));

  case(DAE.CREF_IDENT(ident="length"),BackendDAE.VAR(bindExp=bind), GraphML.SHAPE(ident=ident, shapeType=shapeType, T=T, r=r, r_shape=r_shape, lengthDir=lengthDir, widthDir=widthDir, length=length, width=width, height=height, extra=extra, color=color, specularCoeff=specularCoeff))
    algorithm
      if Util.isSome(bind) then length := Util.getOption(bind);
      else length := BackendVariable.varExp(var);
      end if;
    then (GraphML.SHAPE(ident, shapeType, T, r, r_shape, lengthDir, widthDir, length, width, height, extra, color, specularCoeff));

  case(DAE.CREF_IDENT(ident="width"),BackendDAE.VAR(bindExp=bind), GraphML.SHAPE(ident=ident, shapeType=shapeType, T=T, r=r, r_shape=r_shape, lengthDir=lengthDir, widthDir=widthDir, length=length, width=width, height=height, extra=extra, color=color, specularCoeff=specularCoeff))
    algorithm
      if Util.isSome(bind) then width := Util.getOption(bind);
      else width := BackendVariable.varExp(var);
      end if;
    then (GraphML.SHAPE(ident, shapeType, T, r, r_shape, lengthDir, widthDir, length, width, height, extra, color, specularCoeff));

  case(DAE.CREF_IDENT(ident="height"),BackendDAE.VAR(bindExp=bind), GraphML.SHAPE(ident=ident, shapeType=shapeType, T=T, r=r, r_shape=r_shape, lengthDir=lengthDir, widthDir=widthDir, length=length, width=width, height=height, extra=extra, color=color, specularCoeff=specularCoeff))
    algorithm
      if Util.isSome(bind) then height := Util.getOption(bind);
      else height := BackendVariable.varExp(var);
      end if;
    then (GraphML.SHAPE(ident, shapeType, T, r, r_shape, lengthDir, widthDir, length, width, height, extra, color, specularCoeff));

   case(DAE.CREF_IDENT(ident="extra"),BackendDAE.VAR(bindExp=bind), GraphML.SHAPE(ident=ident, shapeType=shapeType, T=T, r=r, r_shape=r_shape, lengthDir=lengthDir, widthDir=widthDir, length=length, width=width, height=height, extra=extra, color=color, specularCoeff=specularCoeff))
    algorithm
      if Util.isSome(bind) then extra := Util.getOption(bind);
      else extra := BackendVariable.varExp(var);
      end if;
    then (GraphML.SHAPE(ident, shapeType, T, r, r_shape, lengthDir, widthDir, length, width, height, extra, color, specularCoeff));

  case(DAE.CREF_IDENT(ident="color", subscriptLst = {DAE.INDEX(DAE.ICONST(pos))}),BackendDAE.VAR(bindExp=bind), GraphML.SHAPE(ident=ident, shapeType=shapeType, T=T, r=r, r_shape=r_shape, lengthDir=lengthDir, widthDir=widthDir, length=length, width=width, height=height, extra=extra, color=color, specularCoeff=specularCoeff))
    algorithm
      if Util.isSome(bind) then exp := Util.getOption(bind);
      else exp := BackendVariable.varExp(var);
      end if;
      color := arrayUpdate(color,pos,exp);
    then (GraphML.SHAPE(ident, shapeType, T, r, r_shape, lengthDir, widthDir, length, width, height, extra, color, specularCoeff));

   case(DAE.CREF_IDENT(ident="specularCoefficient"),BackendDAE.VAR(bindExp=bind), GraphML.SHAPE(ident=ident, shapeType=shapeType, T=T, r=r, r_shape=r_shape, lengthDir=lengthDir, widthDir=widthDir, length=length, width=width, height=height, extra=extra, color=color, specularCoeff=specularCoeff))
    algorithm
      if Util.isSome(bind) then specularCoeff := Util.getOption(bind);
      else specularCoeff := BackendVariable.varExp(var);
      end if;
    then (GraphML.SHAPE(ident, shapeType, T, r, r_shape, lengthDir, widthDir, length, width, height, extra, color, specularCoeff));

  else
    algorithm
      BackendDAE.VAR(bindExp=bind) := var;
      if Util.isSome(bind) then exp := Util.getOption(bind);
      else exp := DAE.SCONST("NO_BINDING");
      end if;
       //print("whats this? :"+ComponentReference.printComponentRefStr(cref)+" with binding: "+ExpressionDump.printExpStr(exp)+"\n");
    then visIn;
  end matchcontinue;
end fillShapeObject;

protected function printViusalization"printing function for debugging.
author:Waurich TUD 2015-04"
  input GraphML.Visualization vis;
  output String s;
algorithm
  s := match(vis)
    local
      String ident, shapeType;
      DAE.Exp length, width, height;
      array<DAE.Exp> color, r, widthDir, lengthDir;
      array<list<DAE.Exp>> T;
  case(GraphML.SHAPE(ident=ident, shapeType=shapeType, color=color, r=r, lengthDir=lengthDir, widthDir=widthDir, T=T, length=length, width=width, height=height))
  then ("SHAPE "+ident+" '"+shapeType + "' r{"+stringDelimitList(List.map(arrayList(r),ExpressionDump.printExpStr),",")+"}" +
        " lD{"+stringDelimitList(List.map(arrayList(lengthDir),ExpressionDump.printExpStr),",")+"}"+" wD{"+stringDelimitList(List.map(arrayList(widthDir),ExpressionDump.printExpStr),",")+"}"+
        " color("+stringDelimitList(List.map(arrayList(color),ExpressionDump.printExpStr),",")+")"+" w: "+ExpressionDump.printExpStr(width)+" h: "+ExpressionDump.printExpStr(height)+" l: "+ExpressionDump.printExpStr(length) +
        " T {"+ stringDelimitList(List.map(List.flatten(arrayList(T)),ExpressionDump.printExpStr),", ")+"}");
  else
    then "-";
  end match;
end printViusalization;

protected function isVisualizationVar"the var inherits from an visualization object. Therefore, the paths are checked.
author:Waurich TUD 2015-04"
  input BackendDAE.Var var;
  input tuple<list<BackendDAE.Var>,list<String>> tplIn;//visualizationVars, types
  output tuple<list<BackendDAE.Var>,list<String>> tplOut;
algorithm
  tplOut := matchcontinue(var,tplIn)
  local
    Boolean b;
    BackendDAE.Type varType;
    DAE.ComponentRef varName;
    DAE.ElementSource source;
    list<BackendDAE.Var> varLst;
    String obj;
    list<Absyn.Path> paths;
    list<String> paths_lst, typeLst;
    case(BackendDAE.VAR(varName=varName, varType = varType, source=source), (varLst,typeLst))
      algorithm
       paths := DAEUtil.getElementSourceTypes(source);
       paths_lst := List.map(paths, Absyn.pathString);
       obj := hasVisPath(paths);
       true := Util.stringNotEqual(obj,"");
       typeLst := List.unique(obj::typeLst);
    then (var::varLst,typeLst);
    else
      then tplIn;
  end matchcontinue;
end isVisualizationVar;

protected function hasVisPath"checks if the path is Modelica.Mechanics.MultiBody.Visualizers.Advanced.* and outputs * if true.
author:Waurich TUD 2015-04"
  input  list<Absyn.Path> pathsIn;
  output String visPath;
algorithm
  visPath := matchcontinue(pathsIn)
    local
      String name;
      Boolean b;
      Absyn.Path path;
      list<Absyn.Path> rest;
  case({})
    then "";
  case(Absyn.FULLYQUALIFIED(path=path)::rest)
    algorithm
    (name) := hasVisPath(path::rest);
    then name;
  case(Absyn.QUALIFIED(name="Modelica",path=Absyn.QUALIFIED(name="Mechanics",path=Absyn.QUALIFIED(name="MultiBody",path=Absyn.QUALIFIED(name="Visualizers",path=Absyn.QUALIFIED(name="Advanced",path=Absyn.IDENT(name=name))))))::_)
    algorithm
    then name;
  case(_::rest)
    algorithm
      (name) := hasVisPath(rest);
    then name;
  end matchcontinue;
end hasVisPath;

annotation(__OpenModelica_Interface="backend");
end HpcOmTaskGraph;
