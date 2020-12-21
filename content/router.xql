(:
 :  Copyright (C) 2020 TEI Publisher Project Team
 :
 :  This program is free software: you can redistribute it and/or modify
 :  it under the terms of the GNU General Public License as published by
 :  the Free Software Foundation, either version 3 of the License, or
 :  (at your option) any later version.
 :
 :  This program is distributed in the hope that it will be useful,
 :  but WITHOUT ANY WARRANTY; without even the implied warranty of
 :  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 :  GNU General Public License for more details.
 :
 :  You should have received a copy of the GNU General Public License
 :  along with this program.  If not, see <http://www.gnu.org/licenses/>.
 :)
xquery version "3.1";

(:~
 : The core library functions of the OAS router.
 :)
module namespace router="http://exist-db.org/xquery/router";

import module namespace errors="http://exist-db.org/xquery/router/errors";
import module namespace parameters="http://exist-db.org/xquery/router/parameters";

declare variable $router:RESPONSE_CODE := xs:QName("router:RESPONSE_CODE");
declare variable $router:RESPONSE_TYPE := xs:QName("router:RESPONSE_TYPE");
declare variable $router:RESPONSE_BODY := xs:QName("router:RESPONSE_BODY");

(:~
 : May be called from user code to send a response with a particular
 : response code (other than 200). The media type will be determined by
 : looking at the response specification for the given status code.
 :
 : @param code the response code to return
 : @param body data to be sent in the body of the response
 :)
declare function router:response($code as xs:integer, $body as item()*) {
    router:response($code, (), $body)
};

(:~
 : May be called from user code to send a response with a particular
 : response code (other than 200) or media type.
 :
 : @param $code the response code to return
 : @param $mediaType the Content-Type for the response; assumes that the provided body can
 : be converted into the target media type
 : @param $body data to be sent in the body of the response
 :)
declare function router:response($code as xs:integer, $media-type as xs:string?, $body as item()*) {
    map {
        $router:RESPONSE_CODE : $code,
        $router:RESPONSE_TYPE : $media-type,
        $router:RESPONSE_BODY : $body
    }
};

(:~
 : resolve pointer to information in API definition
 :
 : @param $config the API definition
 : @param $ref either a single string from $ref or a sequence of strings 
 :)
declare function router:resolve-pointer($config as map(*), $ref as xs:string*) {
    let $parts := 
        if (starts-with($ref, "#/")) then
            tokenize($ref, "/") (: this is a $ref in the document :)
        else
            $ref (: internal spec lookup :)

    return router:resolve-ref($config, $parts)
};

(:~
 : Maps a request to the configured handler 
 : Loads API definitions, matches routes
 : Calls route handler function returned by $lookup function
 :
 : Route specificity rules:
 : 1. normalize patterns: replace placeholders with "?"
 : 2. use the matching route with the longest normalized pattern
 : 3. If two paths have the same (normalized) length, prioritize by appearance in API files, first one wins
 :)
declare function router:route($api-files as xs:string+, $lookup as function(xs:string) as function(*)?, $middlewares as function(*)*) {
    let $controller := request:get-attribute("$exist:controller")
    let $base-collection := ``[`{repo:get-root()}`/`{$controller}`/]``

    let $request-data := map { 
        "id": util:uuid(),
        "method": request:get-method() => lower-case(),
        "path": request:get-attribute("$exist:path")
    }

    return (
        util:log("info", ``[[`{$request-data?id}`] request `{$request-data?method}` `{$request-data?path}`]``),
        try {
            (: load router definitions :)
            let $specs := 
                for $api-file in $api-files
                let $file-path := concat($base-collection, $api-file)
                let $spec := json-doc($file-path)
                return 
                    if (exists($spec))
                    then ($spec)
                    else error($errors:OPERATION, "Failed to load JSON file from " || $file-path)

            (: find all matching routes :)
            let $matching-routes :=
                for $spec at $pos in $specs
                let $priority := $pos
                return
                    router:match-route($request-data, $spec, $priority)

            let $first-match :=
                if (empty($matching-routes)) then
                    error($errors:NOT_FOUND, "No route matches pattern: " || $request-data?path)
                else if (count($matching-routes) eq 1) then
                    $matching-routes
                else (
                    (: if there are multiple matches, prefer the one matching the longest pattern and the highest priority :)
                    util:log("warn", "ambigous route: " || $request-data?path),
                    head(sort($matching-routes, (), router:route-specificity#1))
                )

            return (
                router:process-request($first-match, $lookup, $middlewares),
                util:log("info", ``[[`{$request-data?id}`] `{$request-data?method}` `{$request-data?path}`: OK]``)
            )

        } catch * {
            let $error :=
                if (router:is-rethrown-error($err:value))
                then $err:value
                (: add line and column for server errors, java exceptions and the like for debugging  :)
                else
                    map {
                        "_error": map {
                            "code": $err:code, "description": $err:description, "value": $err:value, 
                            "line": $err:line-number, "column": $err:column-number, "module": $err:module
                        },
                        "_request": $request-data
                    }
            
            let $status-code :=
                if (contains($error?description, "permission")) then
                    403
                else
                    errors:get-status-code-from-error($err:code)

            return
                router:error($status-code, $error, $lookup)
        }
    )
};

(:~
 : find matching route by checking each path pattern
 :)
declare %private function router:match-route($request as map(*), $spec as map(*), $priority as xs:integer) {
    map:for-each($spec?paths, function ($route-pattern as xs:string, $route-config as map(*)) {
        let $regex := router:create-regex($route-pattern)

        return
            if (matches($request?path, $regex)) then
                map:merge(($request, map {
                    "pattern": $route-pattern,
                    "config": $route-config,
                    "regex": $regex,
                    "spec": $spec,
                    "priority": $priority
                }))
            else 
                ()
    })
};

declare %private variable $router:path-parameter-matcher := "\{[^\}]+\}";

declare %private function router:create-regex($path as xs:string) as xs:string {
    let $components := 
        substring-after($path, "/") (: cut-off first slash :)
        => replace("(\.|\$|\^|\+|\*)", "\\$1") (: escape special characters :)
        => tokenize("/") (: split into components :)

    let $length := count($components)

    let $replaced :=
        for $component at $index in $components
        let $replacement := 
            if ($index = $length)
            then "(.+)"
            else "([^/]+)"
        return replace($component, $router:path-parameter-matcher, $replacement)
    
    return
        "/" || string-join($replaced, "/")
};

(:~
 : Sort routes by specificity
 :)
declare %private function router:route-specificity ($route as map(*)) as xs:integer+ {
    replace($route?pattern, $router:path-parameter-matcher, "?") (: normalize route specificity by replacing path params :)
        => (function ($np as xs:string) { - string-length($np) })() (: sort descending :) (: the longer the more specific :)
    ,
    $route?priority (: sort ascending :)
};

declare %private function router:process-request($pattern-map as map(*), $lookup as function(*), $custom-middlewares as function(*)*) {
    let $route :=
        if (map:contains($pattern-map?config, $pattern-map?method)) then 
            $pattern-map?config?($pattern-map?method)
        else 
            error($errors:METHOD_NOT_ALLOWED, 
                "The method "|| $pattern-map?method || " is not supported for " || $pattern-map?path)

    (: overwrite config field with the specific method handler :)
    let $base-request := map:put($pattern-map, "config", $route)

    let $default-middleware := (
        parameters:in-path#1,
        parameters:in-request#1,
        parameters:body#1
    )

    (: enable arbitrary middleware configuration :)
    let $use := ($default-middleware, $custom-middlewares)
    let $extended-request :=
        fold-left($use, $base-request, function ($request, $next-middleware) {
            $next-middleware($request)
        })

    let $response := router:execute-handler($extended-request, $lookup)

    return router:write-response(200, $response, $route)
};

(:~
 : Look up the XQuery function whose name matches property "operationId".
 : If found, call it and pass the request map as single parameter.
 :)
declare %private function router:execute-handler ($request as map(*), $lookup as function(xs:string) as function(*)?) {
    if (not(map:contains($request?config, "operationId"))) then
        error($errors:OPERATION, "Operation does not define an operationId", $request)
    else
        try {
            let $fn := $lookup($request?config?operationId)
            return $fn($request)
        } catch * {
            (:
             : Catch all errors and add the current route configuration to $err:value,
             : so we can check it later to format the response
             :)
            error($err:code, '', map {
                "_error": map {
                    "code": $err:code, "description": $err:description, "value": $err:value, 
                    "line": $err:line-number, "column": $err:column-number, "module": $err:module
                },
                "_request": $request
            })
        }
};

(: content types :)

declare %private function router:get-content-type-for-code ($config as map(*), $code as xs:integer, $fallback as xs:string) as xs:string {
    let $response-definition := head(($config?responses?($code), $config?responses?default))
    let $content := 
        if (exists($response-definition) and $response-definition instance of map(*))
        then $response-definition?content
        else ()

    return
        if (exists($content))
        then router:get-matching-content-type($content)
        else $fallback
};

(:~
 : Check the list of content types defined for the response
 : and compare with the Accept header sent by the client. Use the
 : first content type if none matches.
 :)
declare %private function router:get-matching-content-type($content-types as map(*)) {
    let $accept := router:accepted-content-types()
    let $matches := filter($accept, map:contains($content-types, ?))

    return
        if (exists($matches))
        then head($matches)
        else head(map:keys($content-types))
};

(:~
 : Tokenize the accept header and return a sequence of content types.
 :)
declare function router:accepted-content-types() as xs:string* {
    let $accept-header := head((request:get-header("accept"), request:get-header("Accept")))
    for $type in tokenize($accept-header, "\s*,\s*")
    return
        replace($type, "^([^;]+).*$", "$1")
};

(:~
 : Q: binary types?
 :)
declare %private function router:method-for-content-type ($type as xs:string) as xs:string {
    switch($type)
        case "application/json" return "json"
        case "text/html" return "html5"
        case "text/text" return "text"
        default return "xml"
};


(:
 : resolve pointers in API definition
 : @throws errors:OPERATION if the pointer cannot be resolved
 :)
declare %private function router:resolve-ref ($config as map(*), $parts as xs:string*) as item()* {
    fold-left($parts, $config, function ($config as item()?, $next as xs:string) as item()? {
        if (empty($next) or $next = ("", "#"))
        then 
            $config
        else if ($config instance of map(*) and map:contains($config, $next))
        then 
            $config?($next)
        else
            error($errors:OPERATION, "could not resolve ref: " || string-join($parts, '/'), $parts)
    })
};

(:~
 : Add line and source info to error description. To avoid outputting multiple locations
 : for rethrown errors, check if $value is set.
 :)
declare function router:error-description($description as xs:string, $line as xs:integer?, $module as xs:string?, $value) {
    if ($line and $line > 0 and empty($value)) then
        ``[`{$description}` [at line `{$line}` of `{($module, 'unknown')[1]}`]]``
    else
        $description
};

(:~
 : Called when an error is caught. Note that users can also throw an error from within a function 
 : to indicate that a different response code should be sent to the client. Errors thrown from user
 : code will have a map with keys "_config" and "_response" as $value, where "_config" is the current
 : oas configuration for the route and "_response" is the response data provided by the user function
 : in the third argument of error().
 :)
declare %private function router:error ($code as xs:integer, $error as map(*), $lookup as function(xs:string) as function(*)?) {
    router:log-error($code, $error),
    (: unwrap error data :)
    let $route := $error?_request?config
    let $error := $error?_error
    return
        (: if an error handler is defined, call it instead of returning the error directly :)
        if (exists($route) and map:contains($route, "x-error-handler"))
        then (
            try {
                let $fn := $lookup($route?x-error-handler)
                return
                    router:write-response($code, $fn($error), $route)
            } catch * {
                let $_error :=
                    map {
                        "code": $err:code,
                        "description": "Failed to execute error handler " || $route?x-error-handler, 
                        "value": $err:value, "module": $err:module,
                        "line": $err:line-number, "column": $err:column-number
                    }
                return (
                    router:log-error(500, $_error),
                    router:default-error-handler(500, $_error)
                )
            }
        )
        (: default error handler :)
        else
            router:default-error-handler($code, $error)
};

declare function router:default-error-handler ($code as xs:integer, $error as map(*)) as item()* {
    response:set-status-code($code),
    response:set-header("Content-Type", "application/json"),
    util:declare-option("output:method", "json"),
    if ($error?description = "") then
        $error?value (: value already contains the data to return :)
    else $error
};

declare %private function router:write-response($default-code as xs:integer, $data as item()*, $config as map(*)) {
    if ($data instance of map(*) and map:contains($data, $router:RESPONSE_CODE))
    then (
        let $code := head(($data?($router:RESPONSE_CODE), $default-code))
        let $content-type := 
            if (exists($data?($router:RESPONSE_TYPE)))
            then $data($router:RESPONSE_TYPE)
            else router:get-content-type-for-code($config, $code, "application/xml")

        return (
            response:set-status-code($code),
            if ($code = 204)
            then ()
            else (
                response:set-header("Content-Type", $content-type),
                util:declare-option("output:method", router:method-for-content-type($content-type)),
                $data?($router:RESPONSE_BODY)
            )
        )
    )
    else (
        let $content-type := router:get-content-type-for-code($config, $default-code, "application/xml")
        return (
            response:set-status-code($default-code),
            response:set-header("Content-Type", $content-type),
            util:declare-option("output:method", router:method-for-content-type($content-type)),
            $data
        )
    )
};

(: helpers :)

declare %private function router:is-rethrown-error($value as item()*) as xs:boolean {
    count($value) eq 1 and
    $value instance of map(*) and
    map:contains($value, "_error")
};

declare %private function router:log-error ($code as xs:integer, $data as map(*)) {
    (: let $request := $data?_request => => serialize(map{"method": "json"}) :)
    let $error := $data?_error => serialize(map{"method": "json"})
    return
        util:log("error", 
            ``[[`{$data?_request?id}`] `{$data?_request?method}` `{$data?_request?path}`: `{$code}`
            `{$error}`]``)
};
