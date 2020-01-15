module NoUnusedExports exposing (rule)

{-| Forbid the use of modules that are never used in your project.


# Rule

@docs rule

-}

-- TODO Don't report type or type aliases (still `A(..)` though) if they are
-- used in exposed function arguments/return values.

import Dict exposing (Dict)
import Elm.Module
import Elm.Project exposing (Project)
import Elm.Syntax.Declaration as Declaration exposing (Declaration)
import Elm.Syntax.Exposing as Exposing
import Elm.Syntax.Expression as Expression exposing (Expression)
import Elm.Syntax.Module as Module exposing (Module)
import Elm.Syntax.ModuleName exposing (ModuleName)
import Elm.Syntax.Node as Node exposing (Node(..))
import Elm.Syntax.Range exposing (Range)
import Elm.Syntax.TypeAnnotation as TypeAnnotation exposing (TypeAnnotation)
import Review.Rule as Rule exposing (Error, Rule)
import Scope2 as Scope
import Set exposing (Set)


{-| Forbid the use of modules that are never used in your project.

A module is considered unused if it does not contain a `main` function
(be it exposed or not), does not import `Test` module, and is never imported in
other modules. For packages, modules listed in the `elm.json`'s
`exposed-modules` are considered used. The `ReviewConfig` is also always
considered as used.

A module will be considered as used if it gets imported, even if none of its
functions or types are used. Other rules from this package will help detect and
remove code so that the import statement is removed.

    config =
        [ NoUnused.Modules.rule
        ]


# When (not) to use this rule

You may not want to enable this rule if you are not concerned about having
unused modules in your application or package.

-}
rule : Rule
rule =
    Rule.newMultiSchema "NoUnused.Exports"
        { moduleVisitorSchema =
            \schema ->
                schema
                    |> Scope.addModuleVisitors
                        { set = \scope context -> { context | scope = scope }
                        , get = .scope
                        }
                    |> Rule.withModuleDefinitionVisitor moduleDefinitionVisitor
                    |> Rule.withDeclarationListVisitor declarationListVisitor
                    |> Rule.withExpressionVisitor expressionVisitor
        , initGlobalContext = initGlobalContext
        , fromGlobalToModule = fromGlobalToModule
        , fromModuleToGlobal = fromModuleToGlobal
        , foldGlobalContexts = foldGlobalContexts
        }
        |> Scope.addGlobalVisitors
            { set = \scope context -> { context | scope = scope }
            , get = .scope
            }
        |> Rule.traversingImportedModulesFirst
        |> Rule.withMultiElmJsonVisitor elmJsonVisitor
        |> Rule.withMultiFinalEvaluation finalEvaluationForProject
        |> Rule.fromMultiSchema



-- CONTEXT


type alias GlobalContext =
    { scope : Scope.GlobalContext
    , projectType : ProjectType
    , modules :
        Dict ModuleName
            { fileKey : Rule.FileKey
            , exposed : Dict String { range : Range, exposedElement : ExposedElement }
            }
    , used : Set ( ModuleName, String )
    }


type ProjectType
    = IsApplication
    | IsPackage (Set (List String))


type ExposedElement
    = Function
    | TypeOrTypeAlias
    | ExposedType


type alias ModuleContext =
    { scope : Scope.ModuleContext
    , exposesEverything : Bool
    , exposed : Dict String { range : Range, exposedElement : ExposedElement }
    , used : Set ( ModuleName, String )
    , typesNotToReport : Set String
    }


initGlobalContext : GlobalContext
initGlobalContext =
    { scope = Scope.initGlobalContext
    , projectType = IsApplication
    , modules = Dict.empty
    , used = Set.empty
    }


fromGlobalToModule : Rule.FileKey -> Node ModuleName -> GlobalContext -> ModuleContext
fromGlobalToModule fileKey moduleName globalContext =
    { scope = Scope.fromGlobalToModule globalContext.scope
    , exposesEverything = False
    , exposed = Dict.empty
    , used = Set.empty
    , typesNotToReport = Set.empty
    }


fromModuleToGlobal : Rule.FileKey -> Node ModuleName -> ModuleContext -> GlobalContext
fromModuleToGlobal fileKey moduleName moduleContext =
    { scope = Scope.fromModuleToGlobal moduleName moduleContext.scope
    , projectType = IsApplication
    , modules =
        Dict.singleton
            (Node.value moduleName)
            { fileKey = fileKey
            , exposed = moduleContext.exposed
            }
    , used =
        moduleContext.typesNotToReport
            |> Set.map (Tuple.pair <| Node.value moduleName)
            |> Set.union moduleContext.used
    }


foldGlobalContexts : GlobalContext -> GlobalContext -> GlobalContext
foldGlobalContexts newContext previousContext =
    { scope = Scope.foldGlobalContexts previousContext.scope newContext.scope
    , projectType = previousContext.projectType
    , modules = Dict.union previousContext.modules newContext.modules
    , used = Set.union newContext.used previousContext.used
    }


registerAsUsed : ( ModuleName, String ) -> ModuleContext -> ModuleContext
registerAsUsed ( moduleName, name ) moduleContext =
    if moduleName /= [] then
        { moduleContext | used = Set.insert ( moduleName, name ) moduleContext.used }

    else
        moduleContext



-- ELM JSON VISITOR


elmJsonVisitor : Maybe Project -> GlobalContext -> GlobalContext
elmJsonVisitor maybeProject globalContext =
    case maybeProject of
        Just (Elm.Project.Package { exposed }) ->
            let
                exposedModuleNames : List Elm.Module.Name
                exposedModuleNames =
                    case exposed of
                        Elm.Project.ExposedList names ->
                            names

                        Elm.Project.ExposedDict fakeDict ->
                            List.concatMap Tuple.second fakeDict
            in
            { globalContext
                | projectType =
                    exposedModuleNames
                        |> List.map (Elm.Module.toString >> String.split ".")
                        |> Set.fromList
                        |> IsPackage
            }

        _ ->
            { globalContext | projectType = IsApplication }



-- GLOBAL EVALUATION


finalEvaluationForProject : GlobalContext -> List Error
finalEvaluationForProject globalContext =
    globalContext.modules
        |> removeExposedPackages globalContext
        |> Dict.toList
        |> List.concatMap
            (\( moduleName, { fileKey, exposed } ) ->
                exposed
                    |> removeApplicationExceptions globalContext moduleName
                    |> Dict.filter (\name _ -> not <| Set.member ( moduleName, name ) globalContext.used)
                    |> Dict.toList
                    |> List.map
                        (\( name, { range, exposedElement } ) ->
                            let
                                what : String
                                what =
                                    case exposedElement of
                                        Function ->
                                            "Exposed function or value"

                                        TypeOrTypeAlias ->
                                            "Exposed type or type alias"

                                        ExposedType ->
                                            "Exposed type"
                            in
                            Rule.errorForFile fileKey
                                { message = what ++ " `" ++ name ++ "` is never used outside this module."
                                , details = [ "This exposed element is never used. You may want to remove it to keep your project clean, and maybe detect some unused code in your project." ]
                                }
                                range
                        )
            )


removeExposedPackages : GlobalContext -> Dict ModuleName a -> Dict ModuleName a
removeExposedPackages globalContext dict =
    case globalContext.projectType of
        IsApplication ->
            dict

        IsPackage exposedModuleNames ->
            Dict.filter (\name _ -> not <| Set.member name exposedModuleNames) dict


removeApplicationExceptions : GlobalContext -> ModuleName -> Dict String a -> Dict String a
removeApplicationExceptions globalContext moduleName dict =
    case globalContext.projectType of
        IsApplication ->
            Dict.remove "main" dict

        IsPackage _ ->
            dict



-- MODULE DEFINITION VISITOR


moduleDefinitionVisitor : Node Module -> ModuleContext -> ( List Error, ModuleContext )
moduleDefinitionVisitor moduleNode moduleContext =
    case Module.exposingList (Node.value moduleNode) of
        Exposing.All _ ->
            ( [], { moduleContext | exposesEverything = True } )

        Exposing.Explicit list ->
            ( [], { moduleContext | exposed = exposedElements list } )


exposedElements : List (Node Exposing.TopLevelExpose) -> Dict String { range : Range, exposedElement : ExposedElement }
exposedElements nodes =
    nodes
        |> List.filterMap
            (\node ->
                case Node.value node of
                    Exposing.FunctionExpose name ->
                        Just <| ( name, { range = Node.range node, exposedElement = Function } )

                    Exposing.TypeOrAliasExpose name ->
                        Just <| ( name, { range = Node.range node, exposedElement = TypeOrTypeAlias } )

                    Exposing.TypeExpose { name } ->
                        Just <| ( name, { range = Node.range node, exposedElement = ExposedType } )

                    Exposing.InfixExpose name ->
                        Nothing
            )
        |> Dict.fromList



-- DECLARATION LIST VISITOR


declarationListVisitor : List (Node Declaration) -> ModuleContext -> ( List Error, ModuleContext )
declarationListVisitor declarations moduleContext =
    let
        declaredNames : Set String
        declaredNames =
            declarations
                |> List.filterMap (Node.value >> declarationName)
                |> Set.fromList

        typesUsedInDeclaration_ : List ( List ( ModuleName, String ), Bool )
        typesUsedInDeclaration_ =
            declarations
                |> List.map (typesUsedInDeclaration moduleContext)

        allUsedTypes : List ( ModuleName, String )
        allUsedTypes =
            typesUsedInDeclaration_
                |> List.concatMap Tuple.first

        contextWithUsedTypes : ModuleContext
        contextWithUsedTypes =
            List.foldl registerAsUsed moduleContext allUsedTypes
    in
    ( []
    , { contextWithUsedTypes
        | exposed =
            contextWithUsedTypes.exposed
                |> (if moduleContext.exposesEverything then
                        identity

                    else
                        Dict.filter (\name _ -> Set.member name declaredNames)
                   )
        , typesNotToReport =
            typesUsedInDeclaration_
                |> List.concatMap
                    (\( list, comesFromCustomTypeWithHiddenConstructors ) ->
                        if comesFromCustomTypeWithHiddenConstructors then
                            []

                        else
                            List.filter (\( moduleName, name ) -> isType name && moduleName == []) list
                    )
                |> List.map Tuple.second
                |> Set.fromList
      }
    )


isType : String -> Bool
isType string =
    case String.uncons string of
        Nothing ->
            False

        Just ( char, _ ) ->
            Char.isUpper char


declarationName : Declaration -> Maybe String
declarationName declaration =
    case declaration of
        Declaration.FunctionDeclaration function ->
            function.declaration
                |> Node.value
                |> .name
                |> Node.value
                |> Just

        Declaration.CustomTypeDeclaration type_ ->
            Just <| Node.value type_.name

        Declaration.AliasDeclaration alias_ ->
            Just <| Node.value alias_.name

        Declaration.PortDeclaration port_ ->
            Just <| Node.value port_.name

        Declaration.InfixDeclaration { operator } ->
            Just <| Node.value operator

        Declaration.Destructuring _ _ ->
            Nothing


typesUsedInDeclaration : ModuleContext -> Node Declaration -> ( List ( ModuleName, String ), Bool )
typesUsedInDeclaration moduleContext declaration =
    case Node.value declaration of
        Declaration.FunctionDeclaration function ->
            ( function.signature
                |> Maybe.map (Node.value >> .typeAnnotation >> collectTypesFromTypeAnnotation moduleContext.scope)
                |> Maybe.withDefault []
            , False
            )

        Declaration.CustomTypeDeclaration type_ ->
            ( type_.constructors
                |> List.concatMap (Node.value >> .arguments)
                |> List.concatMap (collectTypesFromTypeAnnotation moduleContext.scope)
            , not <|
                case Dict.get (Node.value type_.name) moduleContext.exposed |> Maybe.map .exposedElement of
                    Just ExposedType ->
                        True

                    _ ->
                        False
            )

        Declaration.AliasDeclaration alias_ ->
            ( collectTypesFromTypeAnnotation moduleContext.scope alias_.typeAnnotation, False )

        Declaration.PortDeclaration _ ->
            ( [], False )

        Declaration.InfixDeclaration _ ->
            ( [], False )

        Declaration.Destructuring _ _ ->
            ( [], False )


collectTypesFromTypeAnnotation : Scope.ModuleContext -> Node TypeAnnotation -> List ( ModuleName, String )
collectTypesFromTypeAnnotation scope node =
    case Node.value node of
        TypeAnnotation.FunctionTypeAnnotation a b ->
            collectTypesFromTypeAnnotation scope a ++ collectTypesFromTypeAnnotation scope b

        TypeAnnotation.Typed (Node _ ( moduleName, name )) params ->
            Scope.realFunctionOrType moduleName name scope
                :: List.concatMap (collectTypesFromTypeAnnotation scope) params

        TypeAnnotation.Record list ->
            list
                |> List.map (Node.value >> Tuple.second)
                |> List.concatMap (collectTypesFromTypeAnnotation scope)

        TypeAnnotation.GenericRecord name list ->
            list
                |> Node.value
                |> List.map (Node.value >> Tuple.second)
                |> List.concatMap (collectTypesFromTypeAnnotation scope)

        TypeAnnotation.Tupled list ->
            List.concatMap (collectTypesFromTypeAnnotation scope) list

        TypeAnnotation.GenericType _ ->
            []

        TypeAnnotation.Unit ->
            []



-- EXPRESSION VISITOR


expressionVisitor : Node Expression -> Rule.Direction -> ModuleContext -> ( List Error, ModuleContext )
expressionVisitor node direction moduleContext =
    case ( direction, Node.value node ) of
        ( Rule.OnEnter, Expression.FunctionOrValue moduleName name ) ->
            ( []
            , registerAsUsed
                (Scope.realFunctionOrType moduleName name moduleContext.scope)
                moduleContext
            )

        _ ->
            ( [], moduleContext )
