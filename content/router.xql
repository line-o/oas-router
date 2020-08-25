xquery version "3.1";

module namespace router="http://exist-db.org/xquery/router";

import module namespace errors = "http://exist-db.org/xquery/router/errors" at "errors.xql";
import module namespace login="http://exist-db.org/xquery/router/login" at "login.xql";

declare variable $router:CREATED := xs:QName("router:CREATED_201");
declare variable $router:NO_CONTENT := xs:QName("router:NO_CONTENT_204");

declare function router:route($jsonPath as xs:string, $lookup as function(*)) {
    try {
        let $controller := request:get-attribute("$exist:controller")
        let $json := replace(``[`{repo:get-root()}`/`{$controller}`/`{$jsonPath}`]``, "/+", "/")
        let $config := json-doc($json)
        return
            if (exists($config)) then
                router:match-path($config, $lookup)
            else
                error($errors:NOT_FOUND, "Failed to load JSON file from " || $json)
    } catch router:CREATED_201 {
        router:send(201, $err:description, $err:value)
    } catch router:NO_CONTENT_204 {
        router:send(204, $err:description, $err:value)
    } catch errors:NOT_FOUND_404 {
        router:send(404, $err:description, $err:value)
    } catch errors:BAD_REQUEST_400 {
        router:send(400, $err:description, $err:value)
    } catch errors:UNAUTHORIZED_401 {
        router:send(401, $err:description, $err:value)
    } catch errors:FORBIDDEN_403 {
        router:send(401, $err:description, $err:value)
    } catch errors:REQUIRED_PARAM | errors:OPERATION | errors:BODY_CONTENT_TYPE {
        router:send(400, $err:description, $err:value)
    } catch * {
        util:log('ERROR', $err:description),
        router:send(500, $err:description, $err:value)
    }
};

(:~
 : May be called from user code to send a response with a different
 : response code than 200.
 :)
declare function router:response($code as xs:QName, $data as item()*) {
    error($code, "", $data)
};

declare function router:match-path($config as map(*), $lookup as function(*)) {
    let $method := request:get-method() => lower-case()
    let $path := request:get-attribute("$exist:path")
    (: find matching route by checking each path pattern :)
    let $routes := map:for-each($config?paths, function($pattern, $route) {
        if (exists($route($method))) then
            let $regex := router:create-regex($pattern)
            return
                if (matches($path, $regex)) then
                    map {
                        "pattern": $pattern,
                        "config": $route($method),
                        "regex": $regex
                    }
                else
                    ()
        else
            ()
    })
    return
        if (empty($routes)) then
            response:set-status-code(404)
        else
            (: if there are multiple matches, prefer the one matching the longest pattern :)
            let $route := sort($routes, (), function($route) {
                string-length($route?pattern)
            }) => reverse() => head()
            let $loginDomain := router:login-domain($config)
            let $parameters := map:merge((
                router:map-request-parameters($route?config),
                router:map-path-parameters($route, $path)
            ))
            let $request := map {
                "parameters": $parameters,
                "body": router:request-body($route?config),
                "loginDomain": $loginDomain
            }
            return (
                if ($loginDomain) then
                    login:refresh($request)
                else
                    (),
                router:exec($route?config, $request, $lookup) => router:write-response(200, $route?config)
            )
};

(:~
 : Look up the XQuery function whose name matches property "operationId". If found,
 : call it and pass the request map as single parameter.
 :)
declare function router:exec($route as map(*), $request as map(*), $lookup as function(*)) {
    let $operationId := $route?operationId
    return
        if (exists($operationId)) then
            let $fn :=
                try {
                    $lookup($operationId)
                } catch * {
                    error($errors:OPERATION, "Function " || $operationId || " could not be resolved")
                }
            return
                if (exists($fn)) then
                    try {
                        $fn($request)
                    } catch * {
                        (: Catch all errors and add the current route configuration to $err:value,
                           so we can check it later to format the response :)
                        error($err:code, $err:description, map {
                            "_config": $route,
                            "_response": $err:value
                        })
                    }
                else
                    error($errors:OPERATION, "Function " || $operationId || " could not be resolved")
        else
            error($errors:OPERATION, "Operation does not define an operationId")
};

declare function router:write-response($response, $code as xs:int, $config as map(*)) {
    let $respDef := $config?responses?($code)
    let $content := if (exists($respDef)) then $respDef?content else ()
    return
        if (exists($content)) then
            (: currently we're only accepting one content type :)
            let $contentType := router:get-matching-content-type($content)
            return (
                response:set-status-code($code),
                response:set-header("Content-Type", $contentType),
                util:declare-option("output:method", router:method-for-content-type($contentType)),
                $response
            )
        else (
            response:set-status-code($code),
            response:set-header("Content-Type", "text/xml"),
            util:declare-option("output:method", "xml"),
            $response
        )
};

(:~
 : Check the list of content types defined for the response
 : and compare with the Accept header sent by the client. Use the
 : first content type if none matches.
 :)
declare function router:get-matching-content-type($contentTypes as map(*)) {
    let $accept := router:accepted-content-types()
    let $matches := filter($accept, function($type) {
        map:contains($contentTypes, $type)
    })
    return
        if (exists($matches)) then
            $matches[1]
        else
            head(map:keys($contentTypes))
};

(:~
 : Tokenize the accept header and return a sequence of content types.
 :)
declare function router:accepted-content-types() {
    let $header := head((request:get-header("accept"), request:get-header("Accept")))
    for $type in tokenize($header, "\s*,\s*")
    return
        replace($type, "^([^;]+).*$", "$1")
};

declare function router:method-for-content-type($type) {
    switch($type)
        case "application/json" return "json"
        case "text/html" return "html5"
        case "text/text" return "text"
        default return "xml"
};

declare function router:map-path-parameters($route as map(*), $path as xs:string) {
    let $match := analyze-string($route?pattern, "\{([^\}]+)\}")
    let $matchPath := analyze-string($path, $route?regex)
    for $subst in $match//fn:group
    let $value := $matchPath//fn:group[@nr=$subst/@nr]/string()
    let $paramConfig := 
        if (exists($route?config?parameters)) then
            array:filter($route?config?parameters, function($param) {
                $param?name = $subst and $param?in = "path"
            })
        else
            ()
    return
        if (exists($paramConfig) and array:size($paramConfig) > 0) then
            map:entry($subst/string(), router:cast-parameter($value, $paramConfig?1))
        else
            error($errors:REQUIRED_PARAM, "No definition for required path parameter " || $subst)
};

declare function router:map-request-parameters($route as map(*)) {
    let $params := $route?parameters
    return
        if (exists($params)) then
            for $param in $params?*
            where $param?in != "path"
            let $default := if (exists($param?schema)) then $param?schema?default else ()
            let $values := 
                switch ($param?in)
                    case "header" return
                        head((request:get-header($param?name), $default))
                    case "cookie" return
                        head((request:get-cookie-value($param?name), $default))
                    default return
                        request:get-parameter($param?name, $default)
            return
                if ($param?required and empty($values)) then
                    error($errors:REQUIRED_PARAM, "Parameter " || $param?name || " is required")
                else
                    map:entry($param?name, router:cast-parameter($values, $param))
        else
            ()
};

declare function router:cast-parameter($values as xs:string*, $config as map(*)) {
    for $value in $values
    return
        switch($config?schema?type)
            case "integer" return
                if ($config?schema?format) then
                    switch ($config?schema?format)
                        case "int32" case "int64" return
                            xs:int($value)
                        default return
                            xs:integer($value)
                else
                    xs:integer($value)
            case "number" return
                if ($config?schema?format) then
                    switch ($config?schema?format)
                        case "float" return
                            xs:float($value)
                        case "double" return
                            xs:double($value)
                        default return
                            number($value)
                else
                    number($value)
            case "boolean" return
                boolean($value)
            case "string" return
                if ($config?schema?format) then
                    switch ($config?schema?format)
                        case "date" return
                            xs:date($value)
                        case "date-time" return
                            xs:dateTime($value)
                        case "binary" return
                            xs:base64Binary($value)
                        case "byte" return
                            util:binary-to-string(xs:base64Binary($value))
                        default return
                            string($value)
                else
                    string($value)
            default return
                string($value)
};

(:~
 : Try to retrieve and convert the request body if specified
 :)
declare function router:request-body($route as map(*)) {
    if (exists($route?requestBody) and exists($route?requestBody?content)) then
        let $content := $route?requestBody?content
        let $contentTypeHeader := request:get-header("Content-Type")
        return
            if (map:contains($content, $contentTypeHeader)) then
                let $contentType := map:get($content, $contentTypeHeader)
                let $body := request:get-data()
                return
                    switch ($contentTypeHeader)
                        case "application/json" return
                            parse-json(util:binary-to-string($body))
                        case "text/xml" case "application/xml" return
                            $body
                        default return
                            error($errors:BODY_CONTENT_TYPE, "Unable to handle request body content type " || $contentType)
            else
                error($errors:BODY_CONTENT_TYPE, "Passed in Content-Type " || $contentTypeHeader || 
                    " not allowed")
    else
        ()
};

declare function router:create-regex($path as xs:string) {
    let $components := substring-after($path, "/") => replace("\.", "\\.") => tokenize("/")
    let $regex :=
        for $component at $p in $components
        return
            (: replace($component, "\{[^\}]+\}", if ($p = 1) then "(.+?)" else "([^/]+)") :)
            replace($component, "\{[^\}]+\}", "([^/]+)")
    return
        "/" || string-join($regex, "/")
};

declare function router:login-domain($config as map(*)) {
    if (exists($config?security)) then
        let $key := 
            for $entry in $config?security?*
            return
                $entry?cookieAuth
        return
            if (exists($key)) then
                $key?1
            else
                ()
    else
        ()
};

(:~
 : Called when an error is caught. Note that users can also throw an error from within a function 
 : to indicate that a different response code should be sent to the client. Errors thrown from user
 : code will have a map with keys "_config" and "_response" as $value, where "_config" is the current
 : oas configuration for the route and "_response" is the response data provided by the user function
 : in the third argument of error().
 :)
declare function router:send($code as xs:integer, $description as xs:string, $value as item()*) {
    if ($description = "" and count($value) = 1 and $value instance of map(*) and map:contains($value, "_config")) then
        router:write-response(map:get($value, "_response"), $code, map:get($value, "_config"))
    else (
        response:set-status-code($code),
        response:set-header("Content-Type", "application/json"),
        util:declare-option("output:method", "json"),
        if ($description = "") then
            $value
        else
            map {
                "description": $description,
                "details": if (exists($value) and map:contains($value, "_response")) then map:get($value, "_response") else $value
            }
    )
};

declare function router:login($request as map(*)) {
    login:login($request),
    let $user := request:get-attribute($request?loginDomain || ".user")
    return
        if ($user and $user = $request?parameters?user) then
            map {
                "user": $user,
                "groups": array { sm:get-user-groups($user) },
                "dba": sm:is-dba($user),
                "token": request:get-attribute($request?loginDomain || ".token")
            }
        else
            error($errors:UNAUTHORIZED, "Wrong user or password")
};

declare function router:logout($request as map(*)) {
    login:logout($request),
    error($errors:UNAUTHORIZED, "User logged out")
};