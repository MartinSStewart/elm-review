module Scope2Test exposing (all)

import Dependencies
import Elm.Syntax.Declaration as Declaration exposing (Declaration)
import Elm.Syntax.Expression as Expression exposing (Expression)
import Elm.Syntax.Node as Node exposing (Node(..))
import Elm.Syntax.TypeAnnotation as TypeAnnotation exposing (TypeAnnotation)
import Elm.Type
import Review.Project as Project exposing (Project)
import Review.Rule as Rule exposing (Rule)
import Review.Test exposing (ReviewResult)
import Scope2 as Scope
import Test exposing (Test, test)


all : Test
all =
    Test.only <|
        Test.describe "Scope"
            [ realFunctionOrTypeTests
            ]


realFunctionOrTypeTests : Test
realFunctionOrTypeTests =
    Test.describe "Scope.realFunctionOrType"
        [ test "should indicate that module from which a function or value comes from, with knowledge of what is in other modules" <|
            \() ->
                [ """module A exposing (..)
import Bar as Baz exposing (baz)
import ExposesSomeThings exposing (..)
import ExposesEverything exposing (..)
import Foo.Bar
import Html exposing (..)
import Http exposing (get)

localValue = 1

a : SomeCustomType -> SomeTypeAlias -> SomeOtherTypeAlias -> NonExposedCustomType
a = localValue
    unknownValue
    exposedElement
    nonExposedElement
    elementFromExposesEverything
    Foo.bar
    Foo.Bar
    Baz.foo
    baz
    button
    Http.get
    get
    always
    Just
""", """module ExposesSomeThings exposing (SomeOtherTypeAlias, exposedElement)
type NonExposedCustomType = Variant
type alias SomeOtherTypeAlias = {}
exposedElement = 1
nonExposedElement = 2
""", """module ExposesEverything exposing (..)
type SomeCustomType = VariantA | VariantB
type alias SomeTypeAlias = {}
elementFromExposesEverything = 1
""" ]
                    |> Review.Test.runOnModulesWithProjectData project rule
                    |> Review.Test.expectErrorsForModules
                        [ ( "A"
                          , [ Review.Test.error
                                { message = """
<nothing>.SomeCustomType -> ExposesEverything.SomeCustomType
<nothing>.SomeTypeAlias -> ExposesEverything.SomeTypeAlias
<nothing>.SomeOtherTypeAlias -> ExposesSomeThings.SomeOtherTypeAlias
<nothing>.NonExposedCustomType -> <nothing>.NonExposedCustomType
<nothing>.localValue -> <nothing>.localValue
<nothing>.unknownValue -> <nothing>.unknownValue
<nothing>.exposedElement -> ExposesSomeThings.exposedElement
<nothing>.nonExposedElement -> <nothing>.nonExposedElement
<nothing>.elementFromExposesEverything -> ExposesEverything.elementFromExposesEverything
Foo.bar -> Foo.bar
Foo.Bar -> Foo.Bar
Baz.foo -> Bar.foo
<nothing>.baz -> Bar.baz
<nothing>.button -> Html.button
Http.get -> Http.get
<nothing>.get -> Http.get
<nothing>.always -> Basics.always
<nothing>.Just -> Maybe.Just"""
                                , details = [ "details" ]
                                , under = "module"
                                }
                            ]
                          )
                        , ( "ExposesSomeThings"
                          , [ Review.Test.error
                                { message = ""
                                , details = [ "details" ]
                                , under = "module"
                                }
                            ]
                          )
                        , ( "ExposesEverything"
                          , [ Review.Test.error
                                { message = ""
                                , details = [ "details" ]
                                , under = "module"
                                }
                            ]
                          )
                        ]
        ]


type alias GlobalContext =
    { scope : Scope.GlobalContext
    }


type alias ModuleContext =
    { scope : Scope.ModuleContext
    , text : String
    }


project : Project
project =
    Project.new
        |> Project.withDependency Dependencies.elmCore
        |> Project.withDependency Dependencies.elmHtml


scopeGetterSetter =
    { set = \scope context -> { context | scope = scope }
    , get = .scope
    }


rule : Rule
rule =
    Rule.newMultiSchema "TestRule"
        { moduleVisitorSchema =
            \schema ->
                schema
                    |> Scope.addModuleVisitors scopeGetterSetter
                    |> Rule.withDeclarationVisitor declarationVisitor
                    |> Rule.withExpressionVisitor expressionVisitor
                    |> Rule.withFinalEvaluation finalEvaluation
        , initGlobalContext = { scope = Scope.initGlobalContext }
        , fromGlobalToModule =
            \fileKey moduleNameNode globalContext ->
                { scope = Scope.fromGlobalToModule globalContext.scope
                , text = ""
                }
        , fromModuleToGlobal =
            \fileKey moduleNameNode moduleContext ->
                { scope = Scope.fromModuleToGlobal moduleNameNode moduleContext.scope
                }
        , foldGlobalContexts = \a b -> { scope = Scope.foldGlobalContexts a.scope b.scope }
        }
        |> Scope.addGlobalVisitors scopeGetterSetter
        |> Rule.traversingImportedModulesFirst
        |> Rule.fromMultiSchema


declarationVisitor : Node Declaration -> Rule.Direction -> ModuleContext -> ( List Rule.Error, ModuleContext )
declarationVisitor node direction context =
    case ( direction, Node.value node ) of
        ( Rule.OnEnter, Declaration.FunctionDeclaration function ) ->
            case function.signature |> Maybe.map (Node.value >> .typeAnnotation) of
                Nothing ->
                    ( [], context )

                Just typeAnnotation ->
                    ( [], { context | text = context.text ++ "\n" ++ typeAnnotationNames context.scope typeAnnotation } )

        _ ->
            ( [], context )


typeAnnotationNames : Scope.ModuleContext -> Node TypeAnnotation -> String
typeAnnotationNames scope typeAnnotation =
    case Node.value typeAnnotation of
        TypeAnnotation.GenericType name ->
            "<nothing>." ++ name ++ " -> <generic>"

        TypeAnnotation.Typed (Node _ ( moduleName, typeName )) typeParameters ->
            -- Elm.Type.Type (String.join "." moduleName ++ "." ++ typeName) (List.map syntaxTypeAnnotationToDocsType typeParameters)
            let
                nameInCode : String
                nameInCode =
                    case moduleName of
                        [] ->
                            "<nothing>." ++ typeName

                        _ ->
                            String.join "." moduleName ++ "." ++ typeName

                realName : String
                realName =
                    case Scope.realFunctionOrType moduleName typeName scope of
                        ( [], name_ ) ->
                            "<nothing>." ++ name_

                        ( moduleName_, name_ ) ->
                            String.join "." moduleName_ ++ "." ++ name_
            in
            nameInCode ++ " -> " ++ realName

        TypeAnnotation.Unit ->
            "unknown"

        TypeAnnotation.Tupled typeAnnotationTypeAnnotationSyntaxElmNodeNodeSyntaxElmListList ->
            "unknown"

        TypeAnnotation.Record recordDefinitionTypeAnnotationSyntaxElm ->
            "unknown"

        TypeAnnotation.GenericRecord stringStringNodeNodeSyntaxElm recordDefinitionTypeAnnotationSyntaxElmNodeNodeSyntaxElm ->
            "unknown"

        TypeAnnotation.FunctionTypeAnnotation arg returnType ->
            typeAnnotationNames scope arg ++ "\n" ++ typeAnnotationNames scope returnType


expressionVisitor : Node Expression -> Rule.Direction -> ModuleContext -> ( List Rule.Error, ModuleContext )
expressionVisitor node direction context =
    case ( direction, Node.value node ) of
        ( Rule.OnEnter, Expression.FunctionOrValue moduleName name ) ->
            let
                nameInCode : String
                nameInCode =
                    case moduleName of
                        [] ->
                            "<nothing>." ++ name

                        _ ->
                            String.join "." moduleName ++ "." ++ name

                realName : String
                realName =
                    case Scope.realFunctionOrType moduleName name context.scope of
                        ( [], name_ ) ->
                            "<nothing>." ++ name_

                        ( moduleName_, name_ ) ->
                            String.join "." moduleName_ ++ "." ++ name_
            in
            ( [], { context | text = context.text ++ "\n" ++ nameInCode ++ " -> " ++ realName } )

        _ ->
            ( [], context )


finalEvaluation : ModuleContext -> List Rule.Error
finalEvaluation context =
    [ Rule.error { message = context.text, details = [ "details" ] }
        { start = { row = 1, column = 1 }
        , end = { row = 1, column = 7 }
        }
    ]