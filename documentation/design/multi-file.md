# (Ongoing) API design for multi-file support

## Main idea

Currently, `elm-review` only looks at a single file at a time, and when it looks at another file, it has forgotten about the previous file. This is fine for a number of rules, but in a lot of cases, if you want to report problems completely, then you need to be able to know what is happening in multiple files.

Here are a few examples:
- You want to know when a module is never used. For that, you need to go through your whole project, register the used modules, and report the ones that were never imported.
- You want to know when a type constructor of an custom type is never used. If the type is opaque or not exposed, this can be done currently without needing to look at other files. But if the type's constructors are exposed, then you need to know if other files use them.

## Problems to fix

- [X] Be able to have a list containing single file and multi-file rules.
  Users should not have to care if the rule is for a single or multiple files
- [X] Be able to create a multi-file rule
- [X] Be able to specify a multi-file rule's file visitor
    - [X] Using the same functions as for a single rule
    - [X] Forbid specifying a name
    - [X] Forbid specifying an elmJsonVisitor
- [X] Be able to run both types of rules and get a list of errors
- [X] Be able to re-run a rule when a file has changed
    - [X] For single rules, re-run the rule on the file and replace the errors on the file
    - [X] For multi rules:
        - For every file, keep and associate to the file the resulting context and the errors thrown while visiting
        - When a file changes, recompute the associated context and errors (and keep them)
        - Re-merge the contexts, call finalEvaluation and concatenate the errors of the other files
- [ ] Polish type and functions names
- [ ] Replace the phantom types by custom types, instead of records
- [ ] Folding context
    - [ ] Make a nice API for when the multi-file context is different as the file visitor's
    - [ ] Make a nice API for when the multi-file context is the same as the file visitor's
- [ ] Add a way to test multi-file rules
    - [ ] Make sure that the order does not matter by running a rule several
      times with a different order for the files every time.

## Work on errors

- [X] Define a way to report errors in other files?
    - A FileKey/FileId similar to a Navigation.Key? It has no useful meaning, but
      makes it so you can't give an error to a non-existing file or file you haven't visited.
- [ ] Allow multi-file to generate errors without a file key (and make sure that they point to the right file)
- [ ] Define a way to report errors in elm.json?
- [ ] Get rid of Review.Error
    - [ ] Need to be able to create an error without a file in Review.Rule

## Extract the underlying workings into a different package?

`elm-review` does a lot of things that pave the way for other potential tools, like codemods, code crawlers
(to gather data and do something with it, like code generation, project graph visualization).

Maybe we could extract the underlying implementation for `elm-review` into another package that does most of the work, and have `elm-review` be a specific implementation of this crawler that gathers errors as you go?

It is probably not worth doing this at the moment, as we'd first need to explore how the other tools would work and need.