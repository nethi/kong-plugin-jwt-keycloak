local BasePlugin = require "kong.plugins.base_plugin"
local constants = require "kong.constants"
local jwt_decoder = require "kong.plugins.jwt.jwt_parser"
local socket = require "socket"
local keycloak_keys = require("kong.plugins.jwt-keycloak.keycloak_keys")

local validate_issuer = require("kong.plugins.jwt-keycloak.validators.issuers").validate_issuer
local validate_scope = require("kong.plugins.jwt-keycloak.validators.scope").validate_scope
local validate_roles = require("kong.plugins.jwt-keycloak.validators.roles").validate_roles
local validate_realm_roles = require("kong.plugins.jwt-keycloak.validators.roles").validate_realm_roles
local validate_client_roles = require("kong.plugins.jwt-keycloak.validators.roles").validate_client_roles

local re_gmatch = ngx.re.gmatch

local JwtKeycloakHandler = BasePlugin:extend()

local priority_env_var = "JWT_KEYCLOAK_PRIORITY"
local priority
if os.getenv(priority_env_var) then
    priority = tonumber(os.getenv(priority_env_var))
else
    priority = 1005
end
kong.log.debug('JWT_KEYCLOAK_PRIORITY: ' .. priority)

JwtKeycloakHandler.PRIORITY = priority
JwtKeycloakHandler.VERSION = "1.1.0"

function table_to_string(tbl)
    local result = ""
    for k, v in pairs(tbl) do
        -- Check the key type (ignore any numerical keys - assume its an array)
        if type(k) == "string" then
            result = result.."[\""..k.."\"]".."="
        end

        -- Check the value type
        if type(v) == "table" then
            result = result..table_to_string(v)
        elseif type(v) == "boolean" then
            result = result..tostring(v)
        else
            result = result.."\""..v.."\""
        end
        result = result..","
    end
    -- Remove leading commas from the result
    if result ~= "" then
        result = result:sub(1, result:len()-1)
    end
    return result
end


function table_to_json(tbl)
    local result = ""
    local array = false
    
    if (tbl == nil) then
        return result
    end

    for k, v in pairs(tbl) do
        -- Check the key type (ignore any numerical keys - assume its an array)
        -- TODO: this will result in incorrect serialization if the first element is not decider
        if (k ~= nill and type(k) == "string") then
            result = result.."\""..k.."\""..":"
        else
            array = true
        end

        -- Check the value type
        if type(v) == "table" then
            result =   result .. table_to_json(v) 
        elseif type(v) == "boolean" then
            result = result..tostring(v)
        else
            result = result.."\""..v.."\""
        end
        result = result..","
    end
    -- Remove leading commas from the result
    if result ~= "" then
        result = result:sub(1, result:len()-1)
    end
    
    if (array) then
        result = "[" .. result .. "]"
    else
        result = "{" .. result .. "}"
    end
    return result
end

local function split(s, delimiter)
    local result = {};
    local count = 0 ;
    if (s ~= nil) then
        for match in (s..delimiter):gmatch("(.-)"..delimiter) do
            table.insert(result, match);
            count = count + 1
        end
    end
    return count,result;
end
local function process_claim_key_value(conf, jwt_claims, claim_pattern, claim_key, claim_value)
    local mapped_name = nil

    -- emulate our own simple json path
    -- if # is present in "key", then traverse through claims table for each part separated by "#"
    local count, jsonpaths = split(claim_pattern, "#")
    if (count > 1) then
        -- print(" # found, proceeding " .. tostring(count))
        local curtable = jwt_claims
        local val = curtable
        local index = 0
        for index,key in ipairs(jsonpaths) do
          if type(val) ~= "table" then
             break
          end
          curtable = val
          val = curtable[key]
          if (val == nil) then
            break
          end
          -- print ("processig key:" .. key .. " cur value=" .. tostring(val) .. " index=" .. tostring(index))
          if (index == count) then
            claim_value = val
          end  
        end

    end
    if type(claim_value) == "table" then
        claim_value = table_to_json(claim_value)
    end

    -- process mapped key names
    mapped_name = conf.c2h_name_mapping[claim_key]
    -- print ("mapped name=" .. tostring(mapped_name) .. "claim key=" .. tostring(claim_key) )

    if (mapped_name) then
        claim_key = mapped_name
    end

    return claim_key, claim_value
end
local function get_claim_pattern_to_match(claim_pattern)
    if (claim_pattern == nil) then return claim_pattern end
    local count, paths = split(claim_pattern, "#")
    -- if it matches, we need first part. Otherwise, entire string is in the first part anyway
    return paths[1]
end
local function write_claims_to_headers(conf, jwt_claims)

    local add_header = false
    local claim_key, claim_value
    local matched_pattern = nil

    add_header = (conf.c2h_claim_filter_pattern == nil)
    for claim_key,claim_value in pairs(jwt_claims) do
        -- print ("claim key=" .. claim_key .. " value=" .. tostring(claim_value))
        if conf.c2h_claim_filter_pattern  then
            for _,claim_pattern in pairs(conf.c2h_claim_filter_pattern) do 
                add_header = string.match(claim_key, "^" .. get_claim_pattern_to_match(claim_pattern) .. "$")
                if (add_header) then 
                    matched_pattern = claim_pattern
                    break 
                end
            end
        end
        if add_header then
            claim_key, claim_value = process_claim_key_value(conf, jwt_claims, matched_pattern, claim_key, claim_value) 
            if (conf.c2h_header_prefix) then
                kong.service.request.set_header(conf.c2h_header_prefix .. claim_key, claim_value)
            else
                kong.service.request.set_header(claim_key, claim_value)
            end
        end
    end
end

--- Retrieve a JWT in a request.
-- Checks for the JWT in URI parameters, then in cookies, and finally
-- in the `Authorization` header.
-- @param request ngx request object
-- @param conf Plugin configuration
-- @return token JWT token contained in request (can be a table) or nil
-- @return err
local function retrieve_token(conf)
    local args = kong.request.get_query()
    for _, v in ipairs(conf.uri_param_names) do
        if args[v] then
            return args[v]
        end
    end

    local var = ngx.var
    for _, v in ipairs(conf.cookie_names) do
        local cookie = var["cookie_" .. v]
        if cookie and cookie ~= "" then
            return cookie
        end
    end

    local authorization_header = kong.request.get_header("authorization")
    if authorization_header then
        local iterator, iter_err = re_gmatch(authorization_header, "\\s*[Bb]earer\\s+(.+)")
        if not iterator then
            return nil, iter_err
        end

        local m, err = iterator()
        if err then
            return nil, err
        end

        if m and #m > 0 then
            return m[1]
        end
    end
end

local function write_claims_to_request(conf, jwt_claims)
    
    local addl_claims = {}
    local realm_name = nil


    -- print ("conf.c2h_claim_filter_pattern=" .. table_to_json(conf.c2h_claim_filter_pattern) )
    -- print ("conf.c2h_name_mapping=" .. table_to_json (conf.c2h_name_mapping) )
    -- print ("conf.c2h_header_prefix=" .. conf.c2h_header_prefix)

    write_claims_to_headers(conf, jwt_claims)

    -- extract JWT token, realm-name from ISS and make it available as a claim. Assumes realm-name starts with alpha, followed by one or more alphanumberic, underscore and hyphen
    --  http://foobar.example.com/auth/realms/REALMNAME
    realm_name = ""
    if (jwt_claims.iss) then
        realm_name = string.match(jwt_claims.iss, "(%a[a-zA-Z0-9\\_\\-]*)/?$")
        if (realm_name == nil) then
            realm_name = ""
        end
    end
    local jwt_token = retrieve_token(conf)
    write_claims_to_headers(conf, {realm_name = realm_name, jwt = jwt_token})
    return true
end

function JwtKeycloakHandler:new()
    JwtKeycloakHandler.super.new(self, "jwt-keycloak")
end

local function load_consumer(consumer_id, anonymous)
    local result, err = kong.db.consumers:select { id = consumer_id }
    if not result then
        if anonymous and not err then
            err = 'anonymous consumer "' .. consumer_id .. '" not found'
        end
        return nil, err
    end
    return result
end

local function load_consumer_by_custom_id(custom_id)
    local result, err = kong.db.consumers:select_by_custom_id(custom_id)
    if not result then
        return nil, err
    end
    return result
end

local function set_consumer(consumer, credential, token)
    local set_header = kong.service.request.set_header
    local clear_header = kong.service.request.clear_header

    if consumer and consumer.id then
        set_header(constants.HEADERS.CONSUMER_ID, consumer.id)
    else
        clear_header(constants.HEADERS.CONSUMER_ID)
    end

    if consumer and consumer.custom_id then
        set_header(constants.HEADERS.CONSUMER_CUSTOM_ID, consumer.custom_id)
    else
        clear_header(constants.HEADERS.CONSUMER_CUSTOM_ID)
    end

    if consumer and consumer.username then
        set_header(constants.HEADERS.CONSUMER_USERNAME, consumer.username)
    else
        clear_header(constants.HEADERS.CONSUMER_USERNAME)
    end

    kong.client.authenticate(consumer, credential)

    if credential then
        kong.ctx.shared.authenticated_jwt_token = token -- TODO: wrap in a PDK function?
        ngx.ctx.authenticated_jwt_token = token  -- backward compatibilty only

        if credential.username then
            set_header(constants.HEADERS.CREDENTIAL_USERNAME, credential.username)
        else
            clear_header(constants.HEADERS.CREDENTIAL_USERNAME)
        end

        clear_header(constants.HEADERS.ANONYMOUS)

    else
        clear_header(constants.HEADERS.CREDENTIAL_USERNAME)
        set_header(constants.HEADERS.ANONYMOUS, true)
    end
end

local function get_keys(well_known_endpoint)
    local err = nil
    local keys = nil

    kong.log.debug('Getting public keys from keycloak')
    keys, err = keycloak_keys.get_issuer_keys(well_known_endpoint)
    if err then
        return nil, err
    end

    local decoded_keys = {}
    for i, key in ipairs(keys) do
        decoded_keys[i] = jwt_decoder:base64_decode(key)
    end
    
    kong.log.debug('Number of keys retrieved: ' .. table.getn(decoded_keys))
    return {
        keys = decoded_keys,
        updated_at = socket.gettime(),
    }
end

local function validate_signature(conf, jwt, second_call)
    local err = nil
    local issuer_cache_key = 'issuer_keys_' .. jwt.claims.iss
    
    -- kong.log.err('isser keys' .. jwt.claims.iss)
    -- kong.log.err('well known template' .. conf.well_known_template)
    local well_known_endpoint = keycloak_keys.get_wellknown_endpoint(conf.well_known_template, jwt.claims.iss)
    -- kong.log.err('well known endpoint' .. well_known_endpoint)
    -- Retrieve public keys
    local public_keys, err = kong.cache:get(issuer_cache_key, nil, get_keys, well_known_endpoint, true)

    if not public_keys then
        if err then
            kong.log.err(err)
        end
        return kong.response.exit(403, { message = "Unable to get public key for issuer" })
    end

    -- Verify signatures
    for _, k in ipairs(public_keys.keys) do
        if jwt:verify_signature(k) then
            kong.log.debug('JWT signature verified')
            return nil
        end
    end

    -- We could not validate signature, try to get a new keyset?
    since_last_update = socket.gettime() - public_keys.updated_at
    if not second_call and since_last_update > conf.iss_key_grace_period then
        kong.log.debug('Could not validate signature. Keys updated last ' .. since_last_update .. ' seconds ago')
        kong.cache:invalidate_local(issuer_cache_key)
        return validate_signature(conf, jwt, true)
    end

    return kong.response.exit(401, { message = "Invalid token signature" })
end

local function match_consumer(conf, jwt)
    local consumer, err
    local consumer_id = jwt.claims[conf.consumer_match_claim]

    if conf.consumer_match_claim_custom_id then
        consumer_cache_key = "custom_id_key_" .. consumer_id
        consumer, err = kong.cache:get(consumer_cache_key, nil, load_consumer_by_custom_id, consumer_id, true)
    else
        consumer_cache_key = kong.db.consumers:cache_key(consumer_id)
        consumer, err = kong.cache:get(consumer_cache_key, nil, load_consumer, consumer_id, true)
    end

    if err then
        kong.log.err(err)
    end

    if not consumer and not conf.consumer_match_ignore_not_found then
        return false, { status = 401, message = "Unable to find consumer for token" }
    end

    if consumer then
        set_consumer(consumer, nil, nil)
    end

    return true
end

local function do_authentication(conf)
    -- Retrieve token
    local token, err = retrieve_token(conf)
    if err then
        kong.log.err(err)
        return kong.response.exit(500, { message = "An unexpected error occurred" })
    end

    local token_type = type(token)
    if token_type ~= "string" then
        if token_type == "nil" then
            return false, { status = 401, message = "Unauthorized" }
        elseif token_type == "table" then
            return false, { status = 401, message = "Multiple tokens provided" }
        else
            return false, { status = 401, message = "Unrecognizable token" }
        end
    end

    -- Decode token
    local jwt, err = jwt_decoder:new(token)
    if err then
        return false, { status = 401, message = "Bad token; " .. tostring(err) }
    end


    -- Verify algorithim
    if jwt.header.alg ~= (conf.algorithm or "HS256") then
        return false, {status = 403, message = "Invalid algorithm"}
    end

    -- Verify the JWT registered claims
    local ok_claims, errors = jwt:verify_registered_claims(conf.claims_to_verify)
    if not ok_claims then
        return false, { status = 401, message = "Token claims invalid: " .. table_to_string(errors) }
    end

    -- Verify maximum expiration
    if conf.maximum_expiration ~= nil and conf.maximum_expiration > 0 then
        local ok, errors = jwt:check_maximum_expiration(conf.maximum_expiration)
        if not ok then
            return false, { status = 403, message = "Token claims invalid: " .. table_to_string(errors) }
        end
    end

    -- Verify that the issuer is allowed
    if not validate_issuer(conf.allowed_iss,  jwt.claims, conf.c2h_allwed_iss_prefix_match) then
        return false, { status = 401, message = "Token issuer not allowed" }
    end

    err = validate_signature(conf, jwt)
    if err ~= nil then
        return false, err
    end

    -- Match consumer
    if conf.consumer_match then
        ok, err = match_consumer(conf, jwt)
        if not ok then
            return ok, err
        end
    end

    -- Verify roles or scopes
    local ok, err = validate_scope(conf.scope, jwt.claims)

    if ok then
        ok, err = validate_realm_roles(conf.realm_roles, jwt.claims)
    end

    if ok then
        ok, err = validate_roles(conf.roles, jwt.claims)
    end

    if ok then
        ok, err = validate_client_roles(conf.client_roles, jwt.claims)
    end

    if ok then
        ok, err = write_claims_to_request(conf, jwt.claims)
    end

    if ok then
        kong.ctx.shared.jwt_keycloak_token = jwt
        return true
    end

    return false, { status = 403, message = "Access token does not have the required scope/role: " .. err }
end


function JwtKeycloakHandler:access(conf)
    JwtKeycloakHandler.super.access(self)

    -- check if preflight request and whether it should be authenticated
    if not conf.run_on_preflight and kong.request.get_method() == "OPTIONS" then
        return
    end

    if conf.anonymous and kong.client.get_credential() then
        -- we're already authenticated, and we're configured for using anonymous,
        -- hence we're in a logical OR between auth methods and we're already done.
        return
    end

    local ok, err = do_authentication(conf)
    if not ok then
        if conf.anonymous then
            -- get anonymous user
            local consumer_cache_key = kong.db.consumers:cache_key(conf.anonymous)
            local consumer, err      = kong.cache:get(consumer_cache_key, nil,
                                                    load_consumer,
                                                    conf.anonymous, true)
            if err then
                kong.log.err(err)
                return kong.response.exit(500, { message = "An unexpected error occurred" })
            end

            set_consumer(consumer, nil, nil)
        else
            return kong.response.exit(err.status, err.errors or { message = err.message })
        end
    end
end

return JwtKeycloakHandler
