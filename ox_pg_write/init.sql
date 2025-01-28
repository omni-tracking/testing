CREATE SCHEMA IF NOT EXISTS ot;
GRANT CONNECT ON DATABASE ot TO postgres;

-- Super User;
GRANT ALL ON SCHEMA ot to postgres;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA ot TO postgres;

--
SET search_path TO ot, public;

-- nano id
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- nanoid
CREATE OR REPLACE FUNCTION nanoid(size int DEFAULT 21, alphabet text DEFAULT '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_-')
    RETURNS text
    LANGUAGE plpgsql
    volatile
AS
$$
DECLARE
    idBuilder     text := '';
    i             int  := 0;
    bytes         bytea;
    alphabetIndex int;
    mask          int;
    step          int;
BEGIN
    mask := (2 << cast(floor(log(length(alphabet) - 1) / log(2)) as int)) - 1;
    step := cast(ceil(1.6 * mask * size / length(alphabet)) AS int);

    while true
        loop
            bytes := ot.gen_random_bytes(size);
            while i < size
                loop
                    alphabetIndex := (get_byte(bytes, i) & mask) + 1;
                    if alphabetIndex <= length(alphabet) then
                        idBuilder := idBuilder || substr(alphabet, alphabetIndex, 1);
                        if length(idBuilder) = size then
                            return idBuilder;
                        end if;
                    end if;
                    i = i + 1;
                end loop;

            i := 0;
        end loop;
END
$$;

-- -- nanoid_short
-- CREATE OR REPLACE FUNCTION nanoid_short(size int DEFAULT 10, alphabet text DEFAULT '0123456789abcdefghijklmnopqrstuvwxyz')
--     RETURNS text
--     LANGUAGE plpgsql
--     volatile
-- AS
-- $$
-- DECLARE
--     idBuilder     text := '';
--     i             int  := 0;
--     bytes         bytea;
--     alphabetIndex int;
--     mask          int;
--     step          int;
-- BEGIN
--     mask := (2 << cast(floor(log(length(alphabet) - 1) / log(2)) as int)) - 1;
--     step := cast(ceil(1.6 * mask * size / length(alphabet)) AS int);

--     while true
--         loop
--             bytes := ot.gen_random_bytes(size);
--             while i < size
--                 loop
--                     alphabetIndex := (get_byte(bytes, i) & mask) + 1;
--                     if alphabetIndex <= length(alphabet) then
--                         idBuilder := idBuilder || substr(alphabet, alphabetIndex, 1);
--                         if length(idBuilder) = size then
--                             return idBuilder;
--                         end if;
--                     end if;
--                     i = i + 1;
--                 end loop;

--             i := 0;
--         end loop;
-- END
-- $$;


-- INSERT Process, Workflows, Tasks
CREATE OR REPLACE FUNCTION ot.insert_proj_progress_process_workfloww_tasks(
	tenant_code TEXT,
	project_id TEXT,
    progress_item_id_param TEXT,
	progress_process_template_id_param TEXT,
	created_id TEXT,
	created_name TEXT
)
returns TEXT
language plpgsql
as
$$
declare
	-- Must declare i, j properly !!
	i JSONB; -- workflow config
	j JSONB; -- task config
	inserted_progress_process_id TEXT;
	inserted_progress_workflow_id TEXT;
begin
	-- 1) Process
	WITH CTE AS (
	  SELECT name, process_type, progress_workflow_templates_list
	  FROM ot.proj_progress_process_template
	  WHERE progress_process_template_id = progress_process_template_id_param AND is_active
	)
	INSERT INTO ot.proj_progress_process(
        tenant_code, project_id, progress_item_id, progress_process_template_id, name, process_type,
        created_id, created_name)
	VALUES(tenant_code, project_id, progress_item_id_param, progress_process_template_id_param, (SELECT name FROM CTE), (SELECT process_type FROM CTE), created_id, created_name)
	RETURNING progress_process_id INTO inserted_progress_process_id;

	FOR i IN (
-- 		SELECT value FROM jsonb_array_elements(to_jsonb(progress_workflow_templates_list::JSON)) ORDER BY value->'sequence'
		SELECT arr.item_object
		FROM ot.proj_progress_process_template, jsonb_array_elements(to_jsonb(progress_workflow_templates_list)) with ordinality arr(item_object)
		WHERE progress_process_template_id = progress_process_template_id_param
	)
	LOOP
		-- 2) Workflow
		INSERT INTO ot.proj_progress_workflow(tenant_code, project_id, progress_process_id, name, workflow_type, sequence, weightage, created_id, created_name)
		VALUES(tenant_code, project_id,
			   inserted_progress_process_id,
			   CAST(i->>'name' AS TEXT),
			   CAST(i->>'workflowType' AS TEXT),
			   CAST(i->'sequence' AS INTEGER),
			   CAST(i->'weightage' AS REAL),
			   created_id,
			   created_name
		)
		RETURNING progress_workflow_id INTO inserted_progress_workflow_id;

		-- 	3) Task
		FOR j IN (
			SELECT value FROM jsonb_array_elements(to_jsonb((i->'progressTaskTemplatesList')::JSON)) ORDER BY value->'sequence'
		)
		LOOP
-- 			raise notice '%', j->>'taskType';
			INSERT INTO ot.proj_progress_task(tenant_code, project_id, progress_process_id, progress_workflow_id, name, task_type, sequence, weightage, location, created_id, created_name)
			VALUES(
                    tenant_code,
                    project_id,
				   inserted_progress_process_id,
				   inserted_progress_workflow_id,
				   CAST(j->>'name' AS TEXT),
				   CAST(j->>'taskType' AS TEXT),
				   CAST(j->'sequence' AS INTEGER),
				   CAST(j->'weightage' AS REAL),
				   CAST(j->>'location' AS TEXT),
				   created_id,
				   created_name
			);

		END LOOP;
	END LOOP;

	return inserted_progress_process_id;
end;
$$;

-- SELECT ot.insert_proj_progress_process_workfloww_tasks('NfpUBf', 'G__UUc', 'c3xUuJQps4JjBgFT6Z2_Z', 'Je1VuLBno62F1dAyXWjVd', 'DEMO Root');






-- https://softwaremill.com/implementing-event-sourcing-using-a-relational-database/
-- https://dev.to/kspeakman/event-storage-in-postgres-4dk2

-- ------------------------------- Scope: Sys (1) -----------------------------------
-- 1) System & Control Plane
-- sys_event
CREATE TABLE IF NOT EXISTS ot.sys_event(
    event_id Serial PRIMARY KEY, -- Serial: 8 bytes, 1 to 9223372036854775807
    tenant_code TEXT DEFAULT NULL, -- JTC, HDB, etc
    project_id CHAR(21) DEFAULT NULL, -- NULL: sys_, NON-NULL: app_, proj_, ...
    type TEXT NOT NULL, -- event type: UserRegistered, ApiKeyCreated (always in past tense)
    stream_id TEXT NOT NULL, -- aggregate/stream id: superuser_id, user_id, tenant_id, project_id, ...
    version INT NOT NULL, -- aggregate/stream version sorted by stream_id
    data JSONB NOT NULL, -- JSON payload
    --  meta: supports auditing and tracing. Things like user, execute permission, correlation id, etc.
    meta JSONB DEFAULT NULL,
    scope INT NOT NULL, -- 1 (sys), 2 (app), 3 (tenant), 4 (project)
    created_id CHAR(21) DEFAULT NULL, -- signed in ID: superuserId or userId
    created_time BIGINT DEFAULT (extract(epoch from CURRENT_TIMESTAMP) * 1000),
    --
    local_event_id CHAR(21) DEFAULT NULL,
    local_created_time BIGINT DEFAULT NULL,
    --
    UNIQUE(stream_id, version)
);
-- type: event type, UserRegistered, ApiKeyCreated (always in past tense)
CREATE INDEX IF NOT EXISTS idx_event_type ON ot.sys_event(type);

-- sys_superuser
CREATE TABLE IF NOT EXISTS ot.sys_superuser (
    superuser_id CHAR(21) PRIMARY KEY DEFAULT nanoid(), -- stream_id
    version INT NOT NULL DEFAULT 1, -- from ot.sys_event.version
    email TEXT NOT NULL UNIQUE CHECK (email = lower(email)),
    name VARCHAR(255) NOT NULL CHECK (name <> ''),
    hashed_password TEXT NOT NULL,
    hashed_refresh_token TEXT DEFAULT NULL,
    locale TEXT NOT NULL DEFAULT 'en-US',
    phone TEXT DEFAULT NULL,
    profile_photo TEXT DEFAULT NULL,
    data JSONB DEFAULT NULL,
    --
    is_sys_root BOOLEAN NOT NULL DEFAULT false,
    is_email_verified BOOLEAN NOT NULL DEFAULT false,
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_id CHAR(21) DEFAULT NULL,
    created_name TEXT DEFAULT NULL,
    created_time BIGINT DEFAULT (extract(epoch from CURRENT_TIMESTAMP) * 1000),
    updated_id CHAR(21) DEFAULT NULL,
    updated_name TEXT DEFAULT NULL,
    updated_time BIGINT DEFAULT NULL
);

-- sys_role
CREATE TABLE IF NOT EXISTS ot.sys_role(
    role_id TEXT PRIMARY KEY NOT NULL, -- name of role
    description TEXT DEFAULT NULL,
    created_time BIGINT DEFAULT (extract(epoch from CURRENT_TIMESTAMP) * 1000)
);

-- sys_permission
CREATE TABLE IF NOT EXISTS ot.sys_permission(
    permission_id TEXT PRIMARY KEY NOT NULL, -- name of permission
    description TEXT DEFAULT NULL,
    created_time BIGINT DEFAULT (extract(epoch from CURRENT_TIMESTAMP) * 1000)
);

-- sys_error
CREATE TABLE IF NOT EXISTS ot.sys_error (
    sys_error_id CHAR(21) PRIMARY KEY DEFAULT nanoid(), -- stream_id
    method TEXT DEFAULT NULL,
    message TEXT DEFAULT NULL,
    stack_trace TEXT DEFAULT NULL,
    created_name TEXT DEFAULT NULL,
    created_time BIGINT DEFAULT (extract(epoch from CURRENT_TIMESTAMP) * 1000)
);

-- sys_email_verification
CREATE TABLE IF NOT EXISTS ot.sys_email_verification(
    id CHAR(21) PRIMARY KEY DEFAULT nanoid(),
    email TEXT NOT NULL,
    code TEXT NOT NULL,
    created_time BIGINT DEFAULT (extract(epoch from CURRENT_TIMESTAMP) * 1000),
    expiry_time BIGINT DEFAULT NULL,
    confirmed_time BIGINT DEFAULT NULL
);

-- sys_roles_permissions
CREATE TABLE IF NOT EXISTS ot.sys_roles_permissions(
    stream_id CHAR(21) PRIMARY KEY DEFAULT nanoid(),
    version INT NOT NULL DEFAULT 1,
    role_id TEXT NOT NULL,
    permission_id TEXT NOT NULL,
    --
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_id CHAR(21) DEFAULT NULL,
    created_name TEXT DEFAULT NULL,
    created_time BIGINT DEFAULT (extract(epoch from CURRENT_TIMESTAMP) * 1000),
    --
    UNIQUE (role_id, permission_id),
    FOREIGN KEY(permission_id) REFERENCES ot.sys_permission(permission_id) ON DELETE CASCADE,
    FOREIGN KEY(role_id) REFERENCES ot.sys_role(role_id) ON DELETE CASCADE
);



-- ------------------------------- Scope: App (2) -----------------------------------
-- 2) Application Plane
-- app_user: for (1) sign-in, (2) creating tenant_user in tenant.
-- user: within tenant scope, for all operations inside tenant scope
CREATE TABLE IF NOT EXISTS ot.app_user (
    user_id CHAR(21) PRIMARY KEY DEFAULT nanoid(), -- stream_id
    version INT NOT NULL DEFAULT 1, -- from ot.sys_event.version
    email TEXT NOT NULL UNIQUE CHECK (email = lower(email)),
    name VARCHAR(255) NOT NULL CHECK (name <> ''),
    hashed_password TEXT NOT NULL,
    hashed_refresh_token TEXT DEFAULT NULL,
    locale TEXT NOT NULL DEFAULT 'en-US',
    phone TEXT DEFAULT NULL,
    profile_photo TEXT DEFAULT NULL,
    data JSONB DEFAULT NULL,
    --
    default_portfolio_id CHAR(21) DEFAULT NULL,
    --
    is_email_verified BOOLEAN NOT NULL DEFAULT false,
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_id CHAR(21) DEFAULT NULL,
    created_name TEXT DEFAULT NULL,
    created_time BIGINT DEFAULT (extract(epoch from CURRENT_TIMESTAMP) * 1000),
    updated_id CHAR(21) DEFAULT NULL,
    updated_name TEXT DEFAULT NULL,
    updated_time BIGINT DEFAULT NULL
);

-- app_portfolio
CREATE TABLE IF NOT EXISTS ot.app_portfolio(
    portfolio_id CHAR(21) PRIMARY KEY DEFAULT nanoid(), -- stream_id
    version INT NOT NULL DEFAULT 1, -- from ot.sys_event.version
    name TEXT NOT NULL,
    description TEXT DEFAULT NULL,
    profile_photo TEXT DEFAULT NULL,
    roox_user_id CHAR(21) DEFAULT NULL,
    data JSONB DEFAULT NULL,
    --
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_id CHAR(21) DEFAULT NULL,
    created_name TEXT DEFAULT NULL,
    created_time BIGINT DEFAULT (extract(epoch from CURRENT_TIMESTAMP) * 1000),
    updated_id CHAR(21) DEFAULT NULL,
    updated_name TEXT DEFAULT NULL,
    updated_time BIGINT DEFAULT NULL,
    --
    FOREIGN KEY(roox_user_id) REFERENCES ot.app_user(user_id) ON DELETE CASCADE
);

-- app_service
CREATE TABLE IF NOT EXISTS ot.app_service(
    service_id CHAR(21) PRIMARY KEY DEFAULT nanoid(), -- stream_id
    version INT NOT NULL DEFAULT 1,
    service_code TEXT NOT NULL UNIQUE, -- progresses, ...
    name TEXT NOT NULL, -- Progresses, ...
    app_icon TEXT DEFAULT NULL, -- progresses.png (assets/img/services/progresses.png)
    web_icon TEXT DEFAULT NULL, -- https://xxx/xxx/progresses.png, if app_icon == null, use web_icon
    default_order INT NOT NULL, -- 1, 2, 3, ...
    --
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_id CHAR(21) DEFAULT NULL,
    created_name TEXT DEFAULT NULL,
    created_time BIGINT DEFAULT (extract(epoch from CURRENT_TIMESTAMP) * 1000),
    updated_id CHAR(21) DEFAULT NULL,
    updated_name TEXT DEFAULT NULL,
    updated_time BIGINT DEFAULT NULL
);

-- app_error
CREATE TABLE IF NOT EXISTS ot.app_error (
    app_error_id CHAR(21) PRIMARY KEY DEFAULT nanoid(), -- stream_id
    method TEXT DEFAULT NULL,
    message TEXT DEFAULT NULL,
    stack_trace TEXT DEFAULT NULL,
    created_name TEXT DEFAULT NULL,
    created_time BIGINT DEFAULT (extract(epoch from CURRENT_TIMESTAMP) * 1000)
);

-- app_email_verification
CREATE TABLE IF NOT EXISTS ot.app_email_verification(
    id CHAR(21) PRIMARY KEY DEFAULT nanoid(),
    email TEXT NOT NULL,
    code TEXT NOT NULL,
    created_time BIGINT DEFAULT (extract(epoch from CURRENT_TIMESTAMP) * 1000),
    expiry_time BIGINT DEFAULT NULL,
    confirmed_time BIGINT DEFAULT NULL
);




-- ------------------------------- Scope: Tenant (3) -----------------------------------
-- 3) Tenant Plane (default: no prefix)
-- tenant
CREATE TABLE IF NOT EXISTS ot.tnnt_tenant(
    tenant_id CHAR(21) PRIMARY KEY DEFAULT nanoid(), -- stream_id
    version INT NOT NULL DEFAULT 1, -- from ot.sys_event.version
    tenant_code TEXT NOT NULL UNIQUE CHECK (tenant_code = lower(tenant_code)),
    name TEXT NOT NULL,
    status VARCHAR(64) NOT NULL CHECK (status IN ('active', 'suspended', 'disabled')),
    tier VARCHAR(64) NOT NULL CHECK (tier IN ('essential', 'professional', 'enterprise')),
    roox_user_id CHAR(21) DEFAULT NULL, -- user_id
    contact_user_id CHAR(21) DEFAULT NULL, -- user_id
    --
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_id CHAR(21) DEFAULT NULL,
    created_name TEXT DEFAULT NULL,
    created_time BIGINT DEFAULT (extract(epoch from CURRENT_TIMESTAMP) * 1000),
    updated_id CHAR(21) DEFAULT NULL,
    updated_name TEXT DEFAULT NULL,
    updated_time BIGINT DEFAULT NULL,
    --
    FOREIGN KEY(roox_user_id) REFERENCES ot.app_user(user_id) ON DELETE SET NULL,
    FOREIGN KEY(contact_user_id) REFERENCES ot.app_user(user_id) ON DELETE SET NULL
);

-- group
CREATE TABLE IF NOT EXISTS ot.tnnt_group(
    tenant_code TEXT NOT NULL REFERENCES ot.tnnt_tenant(tenant_code) ON DELETE RESTRICT,
    group_id CHAR(21) PRIMARY KEY DEFAULT nanoid(), -- stream_id
    version INT NOT NULL DEFAULT 1, -- from ot.sys_event.version
    name TEXT NOT NULL, -- "Admin Group", "Support Group", etc
    profile_photo TEXT DEFAULT NULL,
    roox_user_id CHAR(21) DEFAULT NULL,
    data JSONB DEFAULT NULL,
    --
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_id CHAR(21) DEFAULT NULL,
    created_name TEXT DEFAULT NULL,
    created_time BIGINT DEFAULT (extract(epoch from CURRENT_TIMESTAMP) * 1000),
    updated_id CHAR(21) DEFAULT NULL,
    updated_name TEXT DEFAULT NULL,
    updated_time BIGINT DEFAULT NULL,
    --
    FOREIGN KEY(roox_user_id) REFERENCES ot.app_user(user_id) ON DELETE SET NULL
);

-- project
CREATE TABLE IF NOT EXISTS ot.tnnt_project(
    tenant_code TEXT NOT NULL REFERENCES ot.tnnt_tenant(tenant_code) ON DELETE RESTRICT,
    project_id CHAR(21) PRIMARY KEY DEFAULT nanoid(),
    version INT NOT NULL DEFAULT 1, -- from ot.sys_event.version
    project_code TEXT NOT NULL UNIQUE,
    name TEXT NOT NULL,
    description TEXT DEFAULT NULL,
    profile_photo TEXT DEFAULT NULL,
    roox_user_id CHAR(21) DEFAULT NULL,
    service_codes_list TEXT[] DEFAULT NULL,
    demo_service_codes_list TEXT[] DEFAULT NULL,
    data JSONB DEFAULT NULL,
    --
    planned_start_date BIGINT DEFAULT NULL,
    planned_finish_date BIGINT DEFAULT NULL,
    actual_start_date BIGINT DEFAULT NULL,
    actual_finish_date BIGINT DEFAULT NULL,
    is_completed BOOLEAN NOT NULL DEFAULT false,
    --
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_id CHAR(21) DEFAULT NULL,
    created_name TEXT DEFAULT NULL,
    created_time BIGINT DEFAULT (extract(epoch from CURRENT_TIMESTAMP) * 1000),
    updated_id CHAR(21) DEFAULT NULL,
    updated_name TEXT DEFAULT NULL,
    updated_time BIGINT DEFAULT NULL,
    --
    UNIQUE(tenant_code, project_code),
    FOREIGN KEY(roox_user_id) REFERENCES ot.app_user(user_id) ON DELETE SET NULL
);

-- company
CREATE TABLE IF NOT EXISTS ot.tnnt_company (
    tenant_code TEXT NOT NULL REFERENCES ot.tnnt_tenant(tenant_code) ON DELETE RESTRICT,
    company_id CHAR(21) PRIMARY KEY DEFAULT nanoid(), -- stream_id
    version INT NOT NULL DEFAULT 1, -- from ot.sys_event.version
    name TEXT NOT NULL,
    alias TEXT NOT NULL,
    profile_photo TEXT DEFAULT NULL,
    data JSONB DEFAULT NULL,
    --
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_id CHAR(21) DEFAULT NULL,
    created_name TEXT DEFAULT NULL,
    created_time BIGINT DEFAULT (extract(epoch from CURRENT_TIMESTAMP) * 1000),
    updated_id CHAR(21) DEFAULT NULL,
    updated_name TEXT DEFAULT NULL,
    updated_time BIGINT DEFAULT NULL
);


-- many-to-many: app scope ------------------------------------
-- mn_portfolios_users
CREATE TABLE IF NOT EXISTS ot.mn_portfolios_users(
    stream_id CHAR(21) PRIMARY KEY DEFAULT nanoid(),
    portfolio_id CHAR(21) NOT NULL,
    user_id CHAR(21) NOT NULL,
    role_id TEXT DEFAULT 'portfolio_read_write',
    is_admin BOOLEAN NOT NULL DEFAULT false,
    --
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_id CHAR(21) DEFAULT NULL,
    created_name TEXT DEFAULT NULL,
    created_time BIGINT DEFAULT (extract(epoch from CURRENT_TIMESTAMP) * 1000),
    --
    UNIQUE (portfolio_id, user_id),
    FOREIGN KEY(portfolio_id) REFERENCES ot.app_portfolio(portfolio_id) ON DELETE CASCADE,
    FOREIGN KEY(user_id) REFERENCES ot.app_user(user_id) ON DELETE CASCADE,
    FOREIGN KEY(role_id) REFERENCES ot.sys_role(role_id) ON DELETE SET NULL
);

-- many-to-many: tenant scope ------------------------------------
-- mn_groups_users
CREATE TABLE IF NOT EXISTS ot.mn_groups_users(
    stream_id CHAR(21) PRIMARY KEY DEFAULT nanoid(),
    tenant_code TEXT NOT NULL REFERENCES ot.tnnt_tenant(tenant_code) ON DELETE RESTRICT,
    group_id CHAR(21) NOT NULL,
    user_id CHAR(21) NOT NULL,
    role_id TEXT DEFAULT 'group_read_write',
    is_admin BOOLEAN NOT NULL DEFAULT false,
    --
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_id CHAR(21) DEFAULT NULL,
    created_name TEXT DEFAULT NULL,
    created_time BIGINT DEFAULT (extract(epoch from CURRENT_TIMESTAMP) * 1000),
    --
    UNIQUE (group_id, user_id),
    FOREIGN KEY(group_id) REFERENCES ot.tnnt_group(group_id) ON DELETE CASCADE,
    FOREIGN KEY(user_id) REFERENCES ot.app_user(user_id) ON DELETE CASCADE,
    FOREIGN KEY(role_id) REFERENCES ot.sys_role(role_id) ON DELETE SET NULL
);

-- mn_tenants_users
CREATE TABLE IF NOT EXISTS ot.mn_tenants_users(
    stream_id CHAR(21) PRIMARY KEY DEFAULT nanoid(),
    tenant_code TEXT NOT NULL,
    user_id CHAR(21) NOT NULL,
    role_id TEXT DEFAULT 'tenant_read_write',
    is_admin BOOLEAN NOT NULL DEFAULT false,
    --
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_id CHAR(21) DEFAULT NULL,
    created_name TEXT DEFAULT NULL,
    created_time BIGINT DEFAULT (extract(epoch from CURRENT_TIMESTAMP) * 1000),
    --
    UNIQUE (tenant_code, user_id),
    FOREIGN KEY(tenant_code) REFERENCES ot.tnnt_tenant(tenant_code) ON DELETE CASCADE,
    FOREIGN KEY(user_id) REFERENCES ot.app_user(user_id) ON DELETE CASCADE,
    FOREIGN KEY(role_id) REFERENCES ot.sys_role(role_id) ON DELETE SET NULL
);

-- mn_tenants_groups
CREATE TABLE IF NOT EXISTS ot.mn_tenants_groups(
    stream_id CHAR(21) PRIMARY KEY DEFAULT nanoid(),
    tenant_code TEXT NOT NULL,
    group_id CHAR(21) NOT NULL,
    role_id TEXT DEFAULT 'tenant_read_write',
    is_admin BOOLEAN NOT NULL DEFAULT false,
    --
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_id CHAR(21) DEFAULT NULL,
    created_name TEXT DEFAULT NULL,
    created_time BIGINT DEFAULT (extract(epoch from CURRENT_TIMESTAMP) * 1000),
    --
    UNIQUE (tenant_code, group_id),
    FOREIGN KEY(tenant_code) REFERENCES ot.tnnt_tenant(tenant_code) ON DELETE CASCADE,
    FOREIGN KEY(group_id) REFERENCES ot.tnnt_group(group_id) ON DELETE CASCADE,
    FOREIGN KEY(role_id) REFERENCES ot.sys_role(role_id) ON DELETE SET NULL
);

-- Note: Create rows only from api-sys !!
-- Note: service_code !! NOT service_id !!
-- mn_projects_services
CREATE TABLE IF NOT EXISTS ot.mn_projects_services(
    stream_id CHAR(21) PRIMARY KEY DEFAULT nanoid(),
    tenant_code TEXT NOT NULL REFERENCES ot.tnnt_tenant(tenant_code) ON DELETE RESTRICT,
    project_id CHAR(21) NOT NULL,
    service_code TEXT NOT NULL,
    --
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_id CHAR(21) DEFAULT NULL,
    created_name TEXT DEFAULT NULL,
    created_time BIGINT DEFAULT (extract(epoch from CURRENT_TIMESTAMP) * 1000),
    --
    UNIQUE (project_id, service_code),
    FOREIGN KEY(project_id) REFERENCES ot.tnnt_project(project_id) ON DELETE CASCADE,
    FOREIGN KEY(service_code) REFERENCES ot.app_service(service_code) ON DELETE CASCADE
);

-- mn_projects_users
CREATE TABLE IF NOT EXISTS ot.mn_projects_users(
    stream_id CHAR(21) PRIMARY KEY DEFAULT nanoid(),
    tenant_code TEXT NOT NULL REFERENCES ot.tnnt_tenant(tenant_code) ON DELETE RESTRICT,
    project_id CHAR(21) NOT NULL,
    user_id CHAR(21) NOT NULL,
    role_id TEXT DEFAULT 'project_read_write',
    is_admin BOOLEAN NOT NULL DEFAULT false,
    --
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_id CHAR(21) DEFAULT NULL,
    created_name TEXT DEFAULT NULL,
    created_time BIGINT DEFAULT (extract(epoch from CURRENT_TIMESTAMP) * 1000),
    --
    UNIQUE (project_id, user_id),
    FOREIGN KEY(project_id) REFERENCES ot.tnnt_project(project_id) ON DELETE CASCADE,
    FOREIGN KEY(user_id) REFERENCES ot.app_user(user_id) ON DELETE CASCADE,
    FOREIGN KEY(role_id) REFERENCES ot.sys_role(role_id) ON DELETE SET NULL
);

-- mn_projects_groups
CREATE TABLE IF NOT EXISTS ot.mn_projects_groups(
    stream_id CHAR(21) PRIMARY KEY DEFAULT nanoid(),
    tenant_code TEXT NOT NULL REFERENCES ot.tnnt_tenant(tenant_code) ON DELETE RESTRICT,
    project_id CHAR(21) NOT NULL,
    group_id CHAR(21) NOT NULL,
    role_id TEXT DEFAULT 'project_read_write',
    is_admin BOOLEAN NOT NULL DEFAULT false,
    --
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_id CHAR(21) DEFAULT NULL,
    created_name TEXT DEFAULT NULL,
    created_time BIGINT DEFAULT (extract(epoch from CURRENT_TIMESTAMP) * 1000),
    --
    UNIQUE (project_id, group_id),
    FOREIGN KEY(project_id) REFERENCES ot.tnnt_project(project_id) ON DELETE CASCADE,
    FOREIGN KEY(group_id) REFERENCES ot.tnnt_group(group_id) ON DELETE CASCADE,
    FOREIGN KEY(role_id) REFERENCES ot.sys_role(role_id) ON DELETE SET NULL
);

-- Record is inserted when "inserting into ot.mn_projects_users"
-- Record is deleted automatically when deleting from "ot.mn_projects_users"
-- Record can be UPDATED with primary key "project_user_stream_id", by updating "portfolio_id" only !!
-- mn_portfolios_projects
CREATE TABLE IF NOT EXISTS ot.mn_portfolios_projects(
    project_user_stream_id CHAR(21) NOT NULL,
    portfolio_id CHAR(21) NOT NULL,
    project_id CHAR(21) NOT NULL,
    tenant_code TEXT NOT NULL REFERENCES ot.tnnt_tenant(tenant_code) ON DELETE RESTRICT,
    --
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_id CHAR(21) DEFAULT NULL,
    created_name TEXT DEFAULT NULL,
    created_time BIGINT DEFAULT (extract(epoch from CURRENT_TIMESTAMP) * 1000),
    --
    UNIQUE (portfolio_id, project_id),
    FOREIGN KEY(portfolio_id) REFERENCES ot.app_portfolio(portfolio_id) ON DELETE CASCADE,
    FOREIGN KEY(project_id) REFERENCES ot.tnnt_project(project_id) ON DELETE CASCADE,
    FOREIGN KEY(project_user_stream_id) REFERENCES ot.mn_projects_users(stream_id) ON DELETE CASCADE
);

-- mn_companies_users
CREATE TABLE IF NOT EXISTS ot.mn_companies_users(
    stream_id CHAR(21) PRIMARY KEY DEFAULT nanoid(),
    tenant_code TEXT NOT NULL REFERENCES ot.tnnt_tenant(tenant_code) ON DELETE RESTRICT,
    company_id CHAR(21) NOT NULL,
    user_id CHAR(21) NOT NULL,
    role_id TEXT DEFAULT 'company_read_write',
    is_admin BOOLEAN NOT NULL DEFAULT false,
    --
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_id CHAR(21) DEFAULT NULL,
    created_name TEXT DEFAULT NULL,
    created_time BIGINT DEFAULT (extract(epoch from CURRENT_TIMESTAMP) * 1000),
    --
    UNIQUE (company_id, user_id),
    FOREIGN KEY(company_id) REFERENCES ot.tnnt_company(company_id) ON DELETE CASCADE,
    FOREIGN KEY(user_id) REFERENCES ot.app_user(user_id) ON DELETE CASCADE,
    FOREIGN KEY(role_id) REFERENCES ot.sys_role(role_id) ON DELETE SET NULL
);

-- mn_companies_groups
CREATE TABLE IF NOT EXISTS ot.mn_companies_groups(
    stream_id CHAR(21) PRIMARY KEY DEFAULT nanoid(),
    tenant_code TEXT NOT NULL REFERENCES ot.tnnt_tenant(tenant_code) ON DELETE RESTRICT,
    company_id CHAR(21) NOT NULL,
    group_id CHAR(21) NOT NULL,
    role_id TEXT DEFAULT 'company_read_write',
    is_admin BOOLEAN NOT NULL DEFAULT false,
    --
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_id CHAR(21) DEFAULT NULL,
    created_name TEXT DEFAULT NULL,
    created_time BIGINT DEFAULT (extract(epoch from CURRENT_TIMESTAMP) * 1000),
    --
    UNIQUE (company_id, group_id),
    FOREIGN KEY(company_id) REFERENCES ot.tnnt_company(company_id) ON DELETE CASCADE,
    FOREIGN KEY(group_id) REFERENCES ot.tnnt_group(group_id) ON DELETE CASCADE,
    FOREIGN KEY(role_id) REFERENCES ot.sys_role(role_id) ON DELETE SET NULL
);




-- ------------------------------- Scope: Project (4) -----------------------------------
-- 4) Project

---------------- Topic: 'project' --------------------------
-- member: local user in project scope
-- Same user_id, different member id in each ot.tnnt_project
-- Possibly different alias
-- CREATE TABLE IF NOT EXISTS ot.proj_member(
--     tenant_code TEXT NOT NULL REFERENCES ot.tnnt_tenant(tenant_code) ON DELETE RESTRICT,
--     project_id CHAR(21) NOT NULL,
--     user_id CHAR(21) NOT NULL,
--     member_id CHAR(21) PRIMARY KEY DEFAULT nanoid(), -- member_id
--     alias TEXT NOT NULL,
--     data JSONB DEFAULT NULL,
--     --
--     UNIQUE (project_id, user_id), -- UNIQUE !!
--     FOREIGN KEY(project_id) REFERENCES ot.tnnt_project(project_id) ON DELETE CASCADE,
--     FOREIGN KEY(user_id) REFERENCES ot.app_user(user_id) ON DELETE CASCADE,
--     --
--     is_active BOOLEAN NOT NULL DEFAULT true,
--     created_id CHAR(21) DEFAULT NULL,
--     created_name TEXT DEFAULT NULL,
--     created_time BIGINT DEFAULT (extract(epoch from CURRENT_TIMESTAMP) * 1000),
--     updated_id CHAR(21) DEFAULT NULL,
--     updated_name TEXT DEFAULT NULL,
--     updated_time BIGINT DEFAULT NULL
-- );

-- -- proj_group
-- CREATE TABLE IF NOT EXISTS ot.proj_group(
--     tenant_code TEXT NOT NULL REFERENCES ot.tnnt_tenant(tenant_code) ON DELETE RESTRICT,
--     project_id CHAR(21) NOT NULL,
--     group_id CHAR(21) PRIMARY KEY DEFAULT nanoid(),
--     version INT NOT NULL DEFAULT 1, -- from ot.sys_event.version
--     roox_user_id CHAR(21) NOT NULL, -- ot.app_user.user_id
--     name TEXT NOT NULL,
--     -- profile_photo TEXT DEFAULT NULL,
--     data JSONB DEFAULT NULL,
--     --
--     is_active BOOLEAN NOT NULL DEFAULT true,
--     created_id CHAR(21) DEFAULT NULL,
--     created_name TEXT DEFAULT NULL,
--     created_time BIGINT DEFAULT (extract(epoch from CURRENT_TIMESTAMP) * 1000),
--     updated_id CHAR(21) DEFAULT NULL,
--     updated_name TEXT DEFAULT NULL,
--     updated_time BIGINT DEFAULT NULL,
--     --
--     FOREIGN KEY(project_id) REFERENCES ot.tnnt_project(project_id) ON DELETE CASCADE,
--     FOREIGN KEY(roox_user_id) REFERENCES ot.app_user(user_id) ON DELETE SET NULL
-- );

-- -- proj_role
-- -- default: PROJECT_ADMIN, PROJECT_MEMBER, PROJECT_VIEW_ONLY
-- CREATE TABLE IF NOT EXISTS ot.proj_role(
--     tenant_code TEXT NOT NULL REFERENCES ot.tnnt_tenant(tenant_code) ON DELETE RESTRICT,
--     project_id CHAR(21) NOT NULL,
--     role_id CHAR(21) PRIMARY KEY DEFAULT nanoid(),
--     version INT NOT NULL DEFAULT 1, -- from ot.sys_event.version
--     name TEXT NOT NULL,
--     --
--     is_active BOOLEAN NOT NULL DEFAULT true,
--     created_id CHAR(21) DEFAULT NULL,
--     created_name TEXT DEFAULT NULL,
--     created_time BIGINT DEFAULT (extract(epoch from CURRENT_TIMESTAMP) * 1000),
--     updated_id CHAR(21) DEFAULT NULL,
--     updated_name TEXT DEFAULT NULL,
--     updated_time BIGINT DEFAULT NULL,
--     --
--     FOREIGN KEY(project_id) REFERENCES ot.tnnt_project(project_id) ON DELETE CASCADE
-- );

-- -- proj_permission
-- CREATE TABLE IF NOT EXISTS ot.proj_permission(
--     tenant_code TEXT NOT NULL REFERENCES ot.tnnt_tenant(tenant_code) ON DELETE RESTRICT,
--     project_id CHAR(21) NOT NULL,
--     permission_id CHAR(21) PRIMARY KEY DEFAULT nanoid(),
--     version INT NOT NULL DEFAULT 1, -- from ot.sys_event.version
--     name TEXT NOT NULL,
--     --
--     is_active BOOLEAN NOT NULL DEFAULT true,
--     created_id CHAR(21) DEFAULT NULL,
--     created_name TEXT DEFAULT NULL,
--     created_time BIGINT DEFAULT (extract(epoch from CURRENT_TIMESTAMP) * 1000),
--     updated_id CHAR(21) DEFAULT NULL,
--     updated_name TEXT DEFAULT NULL,
--     updated_time BIGINT DEFAULT NULL,
--     --
--     FOREIGN KEY(project_id) REFERENCES ot.tnnt_project(project_id) ON DELETE CASCADE
-- );

-- proj_service
CREATE TABLE IF NOT EXISTS ot.proj_location(
    tenant_code TEXT NOT NULL REFERENCES ot.tnnt_tenant(tenant_code) ON DELETE RESTRICT,
    project_id CHAR(21) NOT NULL,
    location_id CHAR(21) PRIMARY KEY DEFAULT nanoid(),
    version INT NOT NULL DEFAULT 1, -- from ot.sys_event.version
    name TEXT NOT NULL,
    data JSONB DEFAULT NULL,
    --
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_id CHAR(21) DEFAULT NULL,
    created_name TEXT DEFAULT NULL,
    created_time BIGINT DEFAULT (extract(epoch from CURRENT_TIMESTAMP) * 1000),
    updated_id CHAR(21) DEFAULT NULL,
    updated_name TEXT DEFAULT NULL,
    updated_time BIGINT DEFAULT NULL,
    --
    FOREIGN KEY(project_id) REFERENCES ot.tnnt_project(project_id) ON DELETE CASCADE
);

-- proj_file
-- Input File: stone drawing, rebar drawing, etc
CREATE TABLE IF NOT EXISTS ot.proj_file (
    tenant_code TEXT NOT NULL REFERENCES ot.tnnt_tenant(tenant_code) ON DELETE RESTRICT,
    project_id CHAR(21) NOT NULL,
    file_id CHAR(21) PRIMARY KEY DEFAULT nanoid(),
    version INT NOT NULL DEFAULT 1, -- from ot.sys_event.version
    name TEXT NOT NULL, -- name
    file_extension TEXT DEFAULT NULL, -- pdf, doc, excel, ppt, json, jpg, png, ...
    file_name TEXT NOT NULL, -- name.pdf
    data_type TEXT DEFAULT NULL, -- Stone Drawing, Rebar Drawing, Specification, Document, Inspection, ...
    url TEXT DEFAULT NULL,
    tag_ids_list TEXT[] DEFAULT NULL,
    data JSONB DEFAULT NULL, -- [{...},{...}] ordered info
    --
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_id CHAR(21) DEFAULT NULL,
    created_name TEXT DEFAULT NULL,
    created_time BIGINT DEFAULT (extract(epoch from CURRENT_TIMESTAMP) * 1000),
    updated_id CHAR(21) DEFAULT NULL,
    updated_name TEXT DEFAULT NULL,
    updated_time BIGINT DEFAULT NULL,
    --
    FOREIGN KEY(project_id) REFERENCES ot.tnnt_project(project_id) ON DELETE CASCADE
);

-- proj_report
CREATE TABLE IF NOT EXISTS ot.proj_report (
    tenant_code TEXT NOT NULL REFERENCES ot.tnnt_tenant(tenant_code) ON DELETE RESTRICT,
    project_id CHAR(21) NOT NULL,
    report_id CHAR(21) PRIMARY KEY DEFAULT nanoid(),
    version INT NOT NULL DEFAULT 1, -- from ot.sys_event.version
    name TEXT NOT NULL, -- name
    file_extension TEXT DEFAULT NULL, -- pdf
    file_name TEXT NOT NULL, -- name.pdf
    data_type TEXT DEFAULT NULL, -- XXX Report,
    url TEXT DEFAULT NULL,
    tag_ids_list TEXT[] DEFAULT NULL,
    data JSONB DEFAULT NULL, -- [{...},{...}] ordered info
    --
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_id CHAR(21) DEFAULT NULL,
    created_name TEXT DEFAULT NULL,
    created_time BIGINT DEFAULT (extract(epoch from CURRENT_TIMESTAMP) * 1000),
    updated_id CHAR(21) DEFAULT NULL,
    updated_name TEXT DEFAULT NULL,
    updated_time BIGINT DEFAULT NULL,
    --
    FOREIGN KEY(project_id) REFERENCES ot.tnnt_project(project_id) ON DELETE CASCADE
);

-- proj_drawing
CREATE TABLE IF NOT EXISTS ot.proj_drawing (
    tenant_code TEXT NOT NULL REFERENCES ot.tnnt_tenant(tenant_code) ON DELETE RESTRICT,
    project_id CHAR(21) NOT NULL,
    drawing_id CHAR(21) PRIMARY KEY DEFAULT nanoid(),
    version INT NOT NULL DEFAULT 1,
    name TEXT NOT NULL, -- name
    file_extension TEXT DEFAULT NULL, -- pdf
    file_name TEXT NOT NULL, -- name.pdf
    drawing_type TEXT DEFAULT NULL,
    url TEXT DEFAULT NULL,
    tag_ids_list TEXT[] DEFAULT NULL,
    data JSONB DEFAULT NULL, -- [{...},{...}] ordered info
    --
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_id CHAR(21) DEFAULT NULL,
    created_name TEXT DEFAULT NULL,
    created_time BIGINT DEFAULT (extract(epoch from CURRENT_TIMESTAMP) * 1000),
    updated_id CHAR(21) DEFAULT NULL,
    updated_name TEXT DEFAULT NULL,
    updated_time BIGINT DEFAULT NULL,
    --
    FOREIGN KEY(project_id) REFERENCES ot.tnnt_project(project_id) ON DELETE CASCADE
);

-- proj_image
CREATE TABLE IF NOT EXISTS ot.proj_image (
    tenant_code TEXT NOT NULL REFERENCES ot.tnnt_tenant(tenant_code) ON DELETE RESTRICT,
    project_id CHAR(21) NOT NULL,
    image_id CHAR(21) PRIMARY KEY DEFAULT nanoid(),
    version INT NOT NULL DEFAULT 1,
    name TEXT NOT NULL, -- name
    file_extension TEXT DEFAULT NULL, -- jpg
    file_name TEXT NOT NULL, -- name.jpg
    url TEXT DEFAULT NULL,
    tag_ids_list TEXT[] DEFAULT NULL,
    data JSONB DEFAULT NULL, -- [{...},{...}] ordered info
    --
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_id CHAR(21) DEFAULT NULL,
    created_name TEXT DEFAULT NULL,
    created_time BIGINT DEFAULT (extract(epoch from CURRENT_TIMESTAMP) * 1000),
    updated_id CHAR(21) DEFAULT NULL,
    updated_name TEXT DEFAULT NULL,
    updated_time BIGINT DEFAULT NULL,
    --
    FOREIGN KEY(project_id) REFERENCES ot.tnnt_project(project_id) ON DELETE CASCADE
);

-- Extracted IfcElement
-- omni_id: GLOBALLY UNIQUE, e.g. "projectId/panel-marking" for PPVC, "importId/version/expressId" = "projectId/importName/version/expressId" for 2D elements without panel marking
CREATE TABLE IF NOT EXISTS ot.proj_ifc_element (
    tenant_code TEXT NOT NULL REFERENCES ot.tnnt_tenant(tenant_code) ON DELETE RESTRICT,
    project_id CHAR(21) NOT NULL,
    ifc_element_id CHAR(21) PRIMARY KEY DEFAULT nanoid(),
    import_id TEXT NOT NULL, -- "projectId/importName" -> "stream_id"
    version INT NOT NULL DEFAULT 1, -- from ot.sys_event.version
    omni_id TEXT NOT NULL,
    global_id TEXT NOT NULL, -- Global GUID
    express_id BIGINT NOT NULL, -- express ID
    data JSONB DEFAULT NULL,
    -- data {
    --     name TEXT DEFAULT NULL, -- Name
    --     object_type TEXT DEFAULT NULL, -- PPVC, PBU, 2D
    --     object_class TEXT NOT NULL, -- IfcElementAssembly
    --     block TEXT DEFAULT NULL,
    --     level INT DEFAULT NULL,
    -- }
    --
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_id CHAR(21) DEFAULT NULL,
    created_name TEXT DEFAULT NULL,
    created_time BIGINT DEFAULT (extract(epoch from CURRENT_TIMESTAMP) * 1000),
    updated_id CHAR(21) DEFAULT NULL,
    updated_name TEXT DEFAULT NULL,
    updated_time BIGINT DEFAULT NULL,
    --
    -- UNIQUE(import_id, version, express_id),
    UNIQUE(omni_id),
    FOREIGN KEY(project_id) REFERENCES ot.tnnt_project(project_id) ON DELETE CASCADE
);



-- Tag: "Tag x ProgressItem" is M:N mapping
CREATE TABLE IF NOT EXISTS ot.proj_tag (
    tenant_code TEXT NOT NULL REFERENCES ot.tnnt_tenant(tenant_code) ON DELETE RESTRICT,
    project_id CHAR(21) NOT NULL,
    tag_id CHAR(21) PRIMARY KEY DEFAULT nanoid(),
    version INT NOT NULL DEFAULT 1, -- from ot.sys_event.version
    tag_type TEXT DEFAULT NULL, -- RFID, QR, UWB, ...
    tag_text TEXT NOT NULL, -- long string (not UNIQUE, could be re-deployed)
    title TEXT DEFAULT NULL, -- e.g., '$tagType - $tagId'
    subtitle TEXT DEFAULT NULL,
    data JSONB DEFAULT NULL, -- [{...},{...}] ordered info
    --
    is_paired BOOLEAN NOT NULL DEFAULT false,
    paired_id CHAR(21) DEFAULT NULL,
    paired_name TEXT DEFAULT NULL, -- User name
    paired_time BIGINT DEFAULT NULL, -- Time
    unpaired_id CHAR(21) DEFAULT NULL,
    unpaired_name TEXT DEFAULT NULL, -- who unpaired the tag
    unpaired_time BIGINT DEFAULT NULL, -- when (rfid) tag is unpaired
    --
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_id CHAR(21) DEFAULT NULL,
    created_name TEXT DEFAULT NULL,
    created_time BIGINT DEFAULT (extract(epoch from CURRENT_TIMESTAMP) * 1000),
    updated_id CHAR(21) DEFAULT NULL,
    updated_name TEXT DEFAULT NULL,
    updated_time BIGINT DEFAULT NULL,
    --
    FOREIGN KEY(project_id) REFERENCES ot.tnnt_project(project_id) ON DELETE CASCADE
);

-- ProgressGroup
CREATE TABLE IF NOT EXISTS ot.proj_progress_group (
    tenant_code TEXT NOT NULL REFERENCES ot.tnnt_tenant(tenant_code) ON DELETE RESTRICT,
    project_id CHAR(21) NOT NULL,
    progress_group_id CHAR(21) PRIMARY KEY DEFAULT nanoid(),
    version INT NOT NULL DEFAULT 1, -- from ot.sys_event.version
    title TEXT NOT NULL,
    subtitle TEXT DEFAULT NULL,
    data JSONB DEFAULT NULL,
    --
    is_multiple BOOLEAN NOT NULL DEFAULT false,
    percent_complete INTEGER NOT NULL DEFAULT 0, -- workflow: current percent_complete
    --
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_id CHAR(21) DEFAULT NULL,
    created_name TEXT DEFAULT NULL,
    created_time BIGINT DEFAULT (extract(epoch from CURRENT_TIMESTAMP) * 1000),
    updated_id CHAR(21) DEFAULT NULL,
    updated_name TEXT DEFAULT NULL,
    updated_time BIGINT DEFAULT NULL,
    --
    -- UNIQUE(project_id, stream_version, title),
    FOREIGN KEY(project_id) REFERENCES ot.tnnt_project(project_id) ON DELETE CASCADE
);

-- ProgressItem
CREATE TABLE IF NOT EXISTS ot.proj_progress_item (
    tenant_code TEXT NOT NULL REFERENCES ot.tnnt_tenant(tenant_code) ON DELETE RESTRICT,
    project_id CHAR(21) NOT NULL,
    progress_group_id CHAR(21) DEFAULT NULL, -- 1:n
    progress_item_id CHAR(21) PRIMARY KEY DEFAULT nanoid(),
    import_id TEXT DEFAULT NULL,
    data_type TEXT NOT NULL, -- IFC, CSV, JSON, APP, ...
    version INT NOT NULL DEFAULT 1, -- from ot.sys_event.version
    omni_id TEXT NOT NULL, -- ProgressItem's globally unique ID
    -- progress_type: 1) uniquely defining "progress_process_templates_list", 2) data mining
    -- Temporary: PILE,
    -- Structure: PPVC, PBU, COLUMN, BEAM, PLANK
    -- MPE: TANK, EQUIPMENT, SKID, PUMP, INSTRUMENT
    -- Activity:
    progress_type TEXT NOT NULL,
    -- objectType: COMPONENT, ASSEMBLY, CAST-IN-SITU, FABRICATED, ...
    object_type TEXT DEFAULT NULL,
    --
    title TEXT NOT NULL,
    subtitle TEXT DEFAULT NULL,
    progress_process_templates_list JSONB[] DEFAULT NULL,
    data JSONB DEFAULT NULL,
    --
    -- Overall percentComplete and color
    percent_complete INTEGER NOT NULL DEFAULT 0, -- workflow: current percent_complete
    planned_start_date BIGINT DEFAULT NULL,
    planned_finish_date BIGINT DEFAULT NULL,
    actual_start_date BIGINT DEFAULT NULL,
    actual_finish_date BIGINT DEFAULT NULL,
    is_shipping BOOLEAN NOT NULL DEFAULT false,
    is_completed BOOLEAN NOT NULL DEFAULT false,
    completed_time BIGINT DEFAULT NULL,
    -- data {
    --     SN TEXT DEFAULT NULL, -- S/N
    --     block TEXT DEFAULT NULL, -- Block
    --     panel_marking TEXT DEFAULT NULL, -- Panel Marking
    --     level INT DEFAULT NULL, -- Level
    --     part TEXT DEFAULT NULL, -- Part
    --     components TEXT DEFAULT NULL, -- Components
    --     module_no TEXT DEFAULT NULL, -- Module No.
    --     index TEXT DEFAULT NULL, -- Index
    --     cast_location TEXT DEFAULT NULL, -- Cast Location
    --     panel_marking_2 TEXT DEFAULT NULL, -- Panel Marking 2
    --     quantity INT DEFAULT NULL, -- Quantity
    --     volume REAL DEFAULT NULL, -- Volume
    --     location TEXT DEFAULT NULL, -- Location
    --     target_to_cast DATE DEFAULT NULL, -- Target to Cast
    --     cast_date DATE DEFAULT NULL, -- Cast Date
    --     delivery_date DATE DEFAULT NULL, -- Delivery Date
    --     DO TEXT DEFAULT NULL, -- Delivery Order
    --     is_casted BOOLEAN NOT NULL DEFAULT false, -- Casted
    --     is_delivered BOOLEAN NOT NULL DEFAULT false, -- Delivered
    -- }
    --
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_id CHAR(21) DEFAULT NULL,
    created_name TEXT DEFAULT NULL,
    created_time BIGINT DEFAULT (extract(epoch from CURRENT_TIMESTAMP) * 1000),
    updated_id CHAR(21) DEFAULT NULL,
    updated_name TEXT DEFAULT NULL,
    updated_time BIGINT DEFAULT NULL,
    --
    UNIQUE(omni_id),
    FOREIGN KEY(project_id) REFERENCES ot.tnnt_project(project_id) ON DELETE CASCADE,
    FOREIGN KEY(progress_group_id) REFERENCES ot.proj_progress_group(progress_group_id) ON DELETE SET NULL
);
-- 1) {{app-server}}/v1/app/projects/:projectId/process-templates
-- 2) {{app-server}}/v1/app/projects/:projectId/workflow-templates
-- 3) {{app-server}}/v1/app/projects/:projectId/imports/ifc/hdb-ppvc

-- ProgressItem.processTemplatIds: [ProcessTemplate, ... ]

-- proj_progress_process_template: created by Project Admin
CREATE TABLE IF NOT EXISTS ot.proj_progress_process_template(
    tenant_code TEXT NOT NULL REFERENCES ot.tnnt_tenant(tenant_code) ON DELETE RESTRICT,
    project_id CHAR(21) NOT NULL,
    progress_process_template_id CHAR(21) PRIMARY KEY DEFAULT nanoid(), -- stream_id
    version INT NOT NULL DEFAULT 1, -- from ot.sys_event.version
    name TEXT NOT NULL,
    process_type TEXT NOT NULL, -- Procurement, Temporary, Structure, MEP, Payment, FM, ...
    sequence INTEGER NOT NULL,
    data JSONB DEFAULT NULL,
    progress_workflow_templates_list JSONB[] DEFAULT NULL, -- define progressWorkflowTemplates with "sequence, weightage"
    --
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_id CHAR(21) DEFAULT NULL,
    created_name TEXT DEFAULT NULL,
    created_time BIGINT DEFAULT (extract(epoch from CURRENT_TIMESTAMP) * 1000),
    updated_id CHAR(21) DEFAULT NULL,
    updated_name TEXT DEFAULT NULL,
    updated_time BIGINT DEFAULT NULL,
    --
    UNIQUE (project_id, name),
    FOREIGN KEY(project_id) REFERENCES ot.tnnt_project(project_id) ON DELETE CASCADE
);
-- 1) {{app-server}}/v1/app/projects/:projectId/process-templates
-- 2) {{app-server}}/v1/app/projects/:projectId/workflow-templates
-- 3) {{app-server}}/v1/app/projects/:projectId/imports/ifc/hdb-ppvc

--   ProcessTemplate.progressWorkflowTemplateConfigs: [
--     progressWorkflowTemplateConfig [
--       TaskTemplate, ..
--     ], ..
--   ]



-- proj_progress_process: created by user, based on processTemplate
CREATE TABLE IF NOT EXISTS ot.proj_progress_process(
    tenant_code TEXT NOT NULL REFERENCES ot.tnnt_tenant(tenant_code) ON DELETE RESTRICT,
    project_id CHAR(21) NOT NULL,
    progress_item_id CHAR(21) NOT NULL,
    progress_process_template_id CHAR(21) DEFAULT NULL,
    progress_process_id CHAR(21) PRIMARY KEY DEFAULT nanoid(),
    omni_id TEXT DEFAULT NULL,
    version INT NOT NULL DEFAULT 1, -- from ot.sys_event.version
    name TEXT NOT NULL,
    process_type TEXT NOT NULL, -- Procurement, Temporary, Structure, MEP, Payment, FM, ...
    data JSONB DEFAULT NULL,
    --
    -- percentComplete and color for one process
    -- A progress item could have multiple processes!
    percent_complete INTEGER NOT NULL DEFAULT 0, -- workflow-level percent_complete
    is_done BOOLEAN NOT NULL DEFAULT false,
    --
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_id CHAR(21) DEFAULT NULL,
    created_name TEXT DEFAULT NULL,
    created_time BIGINT DEFAULT (extract(epoch from CURRENT_TIMESTAMP) * 1000),
    updated_id CHAR(21) DEFAULT NULL,
    updated_name TEXT DEFAULT NULL,
    updated_time BIGINT DEFAULT NULL,
    --
    FOREIGN KEY(project_id) REFERENCES ot.tnnt_project(project_id) ON DELETE CASCADE,
    FOREIGN KEY(progress_item_id) REFERENCES ot.proj_progress_item(progress_item_id) ON DELETE CASCADE,
    FOREIGN KEY(progress_process_template_id) REFERENCES ot.proj_progress_process_template(progress_process_template_id) ON DELETE SET NULL
);

-- proj_progress_workflow: created by user, based on processTemplate and progressWorkflowTemplate
CREATE TABLE IF NOT EXISTS ot.proj_progress_workflow(
    tenant_code TEXT NOT NULL REFERENCES ot.tnnt_tenant(tenant_code) ON DELETE RESTRICT,
    project_id CHAR(21) NOT NULL,
    progress_process_id CHAR(21) DEFAULT NULL, -- 1:n
    progress_workflow_id CHAR(21) PRIMARY KEY DEFAULT nanoid(),
    version INT NOT NULL DEFAULT 1, -- from ot.sys_event.version
    name TEXT NOT NULL,
    -- Structure: oneOf [Precast, Fitout, Installation]
    -- MEP: oneOf []
    workflow_type TEXT DEFAULT NULL,
    sequence INTEGER NOT NULL, -- obtained from process.process_template_config
    weightage REAL NOT NULL DEFAULT 1.0, -- obtained from process.process_template_config
    data JSONB DEFAULT NULL,
    --
    percent_complete INTEGER NOT NULL DEFAULT 0, -- workflow-level percent_complete
    is_done BOOLEAN NOT NULL DEFAULT false,
    --
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_id CHAR(21) DEFAULT NULL,
    created_name TEXT DEFAULT NULL,
    created_time BIGINT DEFAULT (extract(epoch from CURRENT_TIMESTAMP) * 1000),
    updated_id CHAR(21) DEFAULT NULL,
    updated_name TEXT DEFAULT NULL,
    updated_time BIGINT DEFAULT NULL,
    --
    FOREIGN KEY(project_id) REFERENCES ot.tnnt_project(project_id) ON DELETE CASCADE,
    FOREIGN KEY(progress_process_id) REFERENCES ot.proj_progress_process(progress_process_id) ON DELETE CASCADE
);

-- proj_progress_task (No taskTemplate, get task template info from workflow.progressWorkflowTemplateConfig with sequence/weightage)
CREATE TABLE IF NOT EXISTS ot.proj_progress_task(
    tenant_code TEXT NOT NULL REFERENCES ot.tnnt_tenant(tenant_code) ON DELETE RESTRICT,
    project_id CHAR(21) NOT NULL,
    progress_process_id CHAR(21) NOT NULL,
    progress_workflow_id CHAR(21) NOT NULL, -- obtain "sequence & weightage" from workflow.workflow_template_config
    progress_task_id CHAR(21) PRIMARY KEY DEFAULT nanoid(),
    version INT NOT NULL DEFAULT 1, -- from ot.sys_event.version
    name TEXT NOT NULL,
    task_type TEXT DEFAULT NULL,
    sequence INTEGER NOT NULL, -- obtained from workflow.progressWorkflowTemplateConfig
    weightage REAL NOT NULL DEFAULT 1.0, -- obtained from workflow.progressWorkflowTemplateConfig
    location TEXT DEFAULT NULL,
    data JSONB DEFAULT NULL,
    --
    percent_complete INTEGER NOT NULL DEFAULT 0, -- task-level percent_complete
    is_done BOOLEAN NOT NULL DEFAULT false,
    image_ids_list TEXT[] DEFAULT NULL,
    tag_ids_list TEXT[] DEFAULT NULL,
    remarks TEXT DEFAULT NULL,
    --
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_id CHAR(21) DEFAULT NULL,
    created_name TEXT DEFAULT NULL,
    created_time BIGINT DEFAULT (extract(epoch from CURRENT_TIMESTAMP) * 1000),
    updated_id CHAR(21) DEFAULT NULL,
    updated_name TEXT DEFAULT NULL,
    updated_time BIGINT DEFAULT NULL,
    --
    FOREIGN KEY(project_id) REFERENCES ot.tnnt_project(project_id) ON DELETE CASCADE,
    FOREIGN KEY(progress_process_id) REFERENCES ot.proj_progress_process(progress_process_id) ON DELETE CASCADE,
    FOREIGN KEY(progress_workflow_id) REFERENCES ot.proj_progress_workflow(progress_workflow_id) ON DELETE CASCADE
);

-- proj_progress_task_update, under Task
CREATE TABLE IF NOT EXISTS ot.proj_progress_task_update(
    tenant_code TEXT NOT NULL REFERENCES ot.tnnt_tenant(tenant_code) ON DELETE RESTRICT,
    project_id CHAR(21) NOT NULL,
    progress_task_id CHAR(21) NOT NULL,
    progress_task_update_id CHAR(21) PRIMARY KEY DEFAULT nanoid(),
    --
    percent_complete INTEGER NOT NULL DEFAULT 0, -- task progress: percent complete
    image_ids_list TEXT[] DEFAULT NULL,
    tag_ids_list TEXT[] DEFAULT NULL,
    remarks TEXT DEFAULT NULL,
    geolocation TEXT DEFAULT NULL,
    --
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_id CHAR(21) DEFAULT NULL,
    created_name TEXT DEFAULT NULL, -- alias of member
    created_time BIGINT DEFAULT (extract(epoch from CURRENT_TIMESTAMP) * 1000),
    --
    FOREIGN KEY(project_id) REFERENCES ot.tnnt_project(project_id) ON DELETE CASCADE,
    FOREIGN KEY(progress_task_id) REFERENCES ot.proj_progress_task(progress_task_id) ON DELETE CASCADE
);

-- ------------------------ Form --------------------------------
-- proj_form_template
CREATE TABLE IF NOT EXISTS ot.proj_form_template(
    tenant_code TEXT NOT NULL REFERENCES ot.tnnt_tenant(tenant_code) ON DELETE RESTRICT,
    project_id CHAR(21) NOT NULL,
    form_template_id CHAR(21) PRIMARY KEY DEFAULT nanoid(),
    version INT NOT NULL DEFAULT 1, -- from ot.sys_event.version
    form_category TEXT NOT NULL,
    form_type TEXT NOT NULL,
    name TEXT NOT NULL,
    data JSONB DEFAULT NULL,
    form_group_templates_list JSONB[] DEFAULT NULL,
    --
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_id CHAR(21) DEFAULT NULL,
    created_name TEXT DEFAULT NULL,
    created_time BIGINT DEFAULT (extract(epoch from CURRENT_TIMESTAMP) * 1000),
    updated_id CHAR(21) DEFAULT NULL,
    updated_name TEXT DEFAULT NULL,
    updated_time BIGINT DEFAULT NULL,
    --
    FOREIGN KEY(project_id) REFERENCES ot.tnnt_project(project_id) ON DELETE CASCADE
);


-- proj_form
CREATE TABLE IF NOT EXISTS ot.proj_form (
    tenant_code TEXT NOT NULL REFERENCES ot.tnnt_tenant(tenant_code) ON DELETE RESTRICT,
    project_id CHAR(21) NOT NULL,
    progress_item_ids_list CHAR(21)[] DEFAULT NULL, -- List:
    form_template_id CHAR(21) NOT NULL,
    form_id CHAR(21) PRIMARY KEY DEFAULT nanoid(),
    version INT NOT NULL DEFAULT 1, -- from ot.sys_event.version
    form_category TEXT NOT NULL,
    form_type TEXT NOT NULL,
    title TEXT NOT NULL,
    subtitle TEXT DEFAULT NULL,
    tag_ids_list TEXT[] DEFAULT NULL, -- List: Typical problems
    --
    data JSONB DEFAULT NULL,
    form_group_data_list JSONB[] DEFAULT NULL, -- form groups
    --
    status TEXT DEFAULT NULL, -- DRAFT, Submitted by XXX, Checked by XXX, Approved by XXX
    is_completed BOOLEAN NOT NULL DEFAULT false,
    --
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_id CHAR(21) DEFAULT NULL,
    created_name TEXT DEFAULT NULL,
    created_time BIGINT DEFAULT (extract(epoch from CURRENT_TIMESTAMP) * 1000),
    updated_id CHAR(21) DEFAULT NULL,
    updated_name TEXT DEFAULT NULL,
    updated_time BIGINT DEFAULT NULL,
    --
    FOREIGN KEY(project_id) REFERENCES ot.tnnt_project(project_id) ON DELETE CASCADE,
    FOREIGN KEY(form_template_id) REFERENCES ot.proj_form_template(form_template_id) ON DELETE CASCADE
);

-- proj_form_update
CREATE TABLE IF NOT EXISTS ot.proj_form_update (
    tenant_code TEXT NOT NULL REFERENCES ot.tnnt_tenant(tenant_code) ON DELETE RESTRICT,
    project_id CHAR(21) NOT NULL,
    form_id CHAR(21) NOT NULL,
    form_update_id CHAR(21) PRIMARY KEY DEFAULT nanoid(),
    --
    data JSONB DEFAULT NULL,
    form_group_data_list JSONB[] DEFAULT NULL,
    --
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_id CHAR(21) DEFAULT NULL,
    created_name TEXT DEFAULT NULL,
    created_time BIGINT DEFAULT (extract(epoch from CURRENT_TIMESTAMP) * 1000),
    --
    FOREIGN KEY(project_id) REFERENCES ot.tnnt_project(project_id) ON DELETE CASCADE,
    FOREIGN KEY(form_id) REFERENCES ot.proj_form(form_id) ON DELETE CASCADE
);

-- ------------------ Assignment ---------------------
-- proj_assignment
CREATE TABLE IF NOT EXISTS ot.proj_assignment(
    tenant_code TEXT NOT NULL REFERENCES ot.tnnt_tenant(tenant_code) ON DELETE RESTRICT,
    project_id CHAR(21) NOT NULL,
    assignment_id CHAR(21) PRIMARY KEY DEFAULT nanoid(),
    version INT NOT NULL DEFAULT 1, -- from ot.sys_event.version
    --
    name TEXT NOT NULL,
    type TEXT NOT NULL,
    path TEXT NOT NULL,
    tag_ids_list TEXT[] DEFAULT NULL,
    data JSONB DEFAULT NULL,
    --
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_id CHAR(21) DEFAULT NULL,
    created_name TEXT DEFAULT NULL,
    created_time BIGINT DEFAULT (extract(epoch from CURRENT_TIMESTAMP) * 1000),
    updated_id CHAR(21) DEFAULT NULL,
    updated_name TEXT DEFAULT NULL,
    updated_time BIGINT DEFAULT NULL,
    --
    FOREIGN KEY(project_id) REFERENCES ot.tnnt_project(project_id) ON DELETE CASCADE
);

-- ------------------ Inspection ---------------------
-- proj_inspection_template
CREATE TABLE IF NOT EXISTS ot.proj_inspection_template(
    tenant_code TEXT NOT NULL REFERENCES ot.tnnt_tenant(tenant_code) ON DELETE RESTRICT,
    project_id CHAR(21) NOT NULL,
    inspection_template_id CHAR(21) PRIMARY KEY DEFAULT nanoid(),
    version INT NOT NULL DEFAULT 1, -- from ot.sys_event.version
    name TEXT NOT NULL,
    template_type TEXT NOT NULL,
    info_categories_list JSONB[] DEFAULT NULL, -- InspectionTemplateCategory[]
    info_types_list JSONB[] DEFAULT NULL, -- InspectionTemplateType[]
    info_locations_list JSONB[] DEFAULT NULL, -- InspectionTemplateLocation[]
    info_priorities_list JSONB[] DEFAULT NULL, -- Normal, High, Urgent
    --
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_id CHAR(21) DEFAULT NULL,
    created_name TEXT DEFAULT NULL,
    created_time BIGINT DEFAULT (extract(epoch from CURRENT_TIMESTAMP) * 1000),
    updated_id CHAR(21) DEFAULT NULL,
    updated_name TEXT DEFAULT NULL,
    updated_time BIGINT DEFAULT NULL,
    --
    FOREIGN KEY(project_id) REFERENCES ot.tnnt_project(project_id) ON DELETE CASCADE
);

-- proj_inspection
CREATE TABLE IF NOT EXISTS ot.proj_inspection(
    tenant_code TEXT NOT NULL REFERENCES ot.tnnt_tenant(tenant_code) ON DELETE RESTRICT,
    project_id CHAR(21) NOT NULL,
    progress_item_id CHAR(21) DEFAULT NULL,
    inspection_template_id CHAR(21) DEFAULT NULL, -- customized groups/fields
    inspection_id CHAR(21) PRIMARY KEY DEFAULT nanoid(),
    version INT NOT NULL DEFAULT 1, -- from ot.sys_event.version
    --
    inspection_info_update_id CHAR(21) DEFAULT NULL,
    inspection_assignment_update_id CHAR(21) DEFAULT NULL,
    assignment_id CHAR(21) DEFAULT NULL,
    --
    inspection_step_ids_list TEXT[] DEFAULT NULL,
    status TEXT NOT NULL, -- Draft, Created, Assigned, Rectified, Completed
    is_completed BOOLEAN NOT NULL DEFAULT false,
    --
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_id CHAR(21) DEFAULT NULL,
    created_name TEXT DEFAULT NULL,
    created_time BIGINT DEFAULT (extract(epoch from CURRENT_TIMESTAMP) * 1000),
    updated_id CHAR(21) DEFAULT NULL,
    updated_name TEXT DEFAULT NULL,
    updated_time BIGINT DEFAULT NULL,
    --
    FOREIGN KEY(project_id) REFERENCES ot.tnnt_project(project_id) ON DELETE CASCADE,
    FOREIGN KEY(inspection_template_id) REFERENCES ot.proj_inspection_template(inspection_template_id) ON DELETE SET NULL
);

-- proj_inspection_info_update
CREATE TABLE IF NOT EXISTS ot.proj_inspection_info_update(
    tenant_code TEXT NOT NULL REFERENCES ot.tnnt_tenant(tenant_code) ON DELETE RESTRICT,
    project_id CHAR(21) NOT NULL,
    inspection_id CHAR(21) NOT NULL,
    inspection_info_update_id CHAR(21) PRIMARY KEY DEFAULT nanoid(),
    inspection_step_id CHAR(21) NOT NULL,
    --
    title TEXT DEFAULT NULL,
    remarks TEXT DEFAULT NULL,
    category TEXT DEFAULT NULL,
    type TEXT DEFAULT NULL,
    location TEXT DEFAULT NULL,
    geolocation TEXT DEFAULT NULL,
    priority TEXT DEFAULT NULL,
    image_ids_list TEXT[] DEFAULT NULL,
    tag_ids_list TEXT[] DEFAULT NULL, -- List: Typical problems
    --
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_id CHAR(21) DEFAULT NULL,
    created_name TEXT DEFAULT NULL, -- alias of member
    created_time BIGINT DEFAULT (extract(epoch from CURRENT_TIMESTAMP) * 1000),
    --
    FOREIGN KEY(project_id) REFERENCES ot.tnnt_project(project_id) ON DELETE CASCADE,
    FOREIGN KEY(inspection_id) REFERENCES ot.proj_inspection(inspection_id) ON DELETE CASCADE
);

-- proj_inspection_assignment_update
CREATE TABLE IF NOT EXISTS ot.proj_inspection_assignment_update(
    tenant_code TEXT NOT NULL REFERENCES ot.tnnt_tenant(tenant_code) ON DELETE RESTRICT,
    project_id CHAR(21) NOT NULL,
    inspection_id CHAR(21) NOT NULL,
    inspection_assignment_update_id CHAR(21) PRIMARY KEY DEFAULT nanoid(),
    inspection_step_id CHAR(21) NOT NULL,
    --
    supervisor_ids_list TEXT[] DEFAULT NULL,
    assignee_ids_list TEXT[] DEFAULT NULL,
    due_date BIGINT DEFAULT NULL,
    remarks TEXT DEFAULT NULL,
    --
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_id CHAR(21) DEFAULT NULL,
    created_name TEXT DEFAULT NULL, -- alias of member
    created_time BIGINT DEFAULT (extract(epoch from CURRENT_TIMESTAMP) * 1000),
    --
    FOREIGN KEY(project_id) REFERENCES ot.tnnt_project(project_id) ON DELETE CASCADE,
    FOREIGN KEY(inspection_id) REFERENCES ot.proj_inspection(inspection_id) ON DELETE CASCADE
);

-- proj_inspection_update
CREATE TABLE IF NOT EXISTS ot.proj_inspection_update(
    tenant_code TEXT NOT NULL REFERENCES ot.tnnt_tenant(tenant_code) ON DELETE RESTRICT,
    project_id CHAR(21) NOT NULL,
    inspection_id CHAR(21) NOT NULL,
    inspection_update_id CHAR(21) PRIMARY KEY DEFAULT nanoid(),
    inspection_step_id CHAR(21) NOT NULL,
    --
    type TEXT NOT NULL,
    remarks TEXT DEFAULT NULL,
    image_ids_list TEXT[] DEFAULT NULL,
    tag_ids_list TEXT[] DEFAULT NULL,
    data JSONB DEFAULT NULL,
    --
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_id CHAR(21) DEFAULT NULL,
    created_name TEXT DEFAULT NULL, -- alias of member
    created_time BIGINT DEFAULT (extract(epoch from CURRENT_TIMESTAMP) * 1000),
    --
    FOREIGN KEY(project_id) REFERENCES ot.tnnt_project(project_id) ON DELETE CASCADE,
    FOREIGN KEY(inspection_id) REFERENCES ot.proj_inspection(inspection_id) ON DELETE CASCADE
);

-- proj_inspection_step
CREATE TABLE IF NOT EXISTS ot.proj_inspection_step(
    tenant_code TEXT NOT NULL REFERENCES ot.tnnt_tenant(tenant_code) ON DELETE RESTRICT,
    project_id CHAR(21) NOT NULL,
    inspection_id CHAR(21) NOT NULL,
    inspection_step_id CHAR(21) PRIMARY KEY DEFAULT nanoid(),
    --
    type TEXT NOT NULL,
    status TEXT NOT NULL,
    --
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_id CHAR(21) DEFAULT NULL,
    created_name TEXT DEFAULT NULL, -- alias of member
    created_time BIGINT DEFAULT (extract(epoch from CURRENT_TIMESTAMP) * 1000),
    --
    FOREIGN KEY(project_id) REFERENCES ot.tnnt_project(project_id) ON DELETE CASCADE,
    FOREIGN KEY(inspection_id) REFERENCES ot.proj_inspection(inspection_id) ON DELETE CASCADE
);

-- ================ Dashboard =======================
-- proj_document
CREATE TABLE IF NOT EXISTS ot.proj_document (
    tenant_code TEXT NOT NULL REFERENCES ot.tnnt_tenant(tenant_code) ON DELETE RESTRICT,
    project_id CHAR(21) NOT NULL,
    document_id CHAR(21) PRIMARY KEY DEFAULT nanoid(),
    version INT NOT NULL DEFAULT 1, -- from ot.sys_event.version
    ref_no TEXT NOT NULL,
    title TEXT NOT NULL, -- aka name
    discipline TEXT NOT NULL, -- architecture, structure, mechanical
    type TEXT NOT NULL, -- shop drawing
    target_date BIGINT DEFAULT NULL, -- target approval date
    file_id CHAR(21) DEFAULT NULL,
    is_approved BOOLEAN NOT NULL DEFAULT false,
    data JSONB DEFAULT NULL, --
    --
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_id CHAR(21) DEFAULT NULL,
    created_name TEXT DEFAULT NULL,
    created_time BIGINT DEFAULT (extract(epoch from CURRENT_TIMESTAMP) * 1000),
    updated_id CHAR(21) DEFAULT NULL,
    updated_name TEXT DEFAULT NULL,
    updated_time BIGINT DEFAULT NULL,
    --
    FOREIGN KEY(project_id) REFERENCES ot.tnnt_project(project_id) ON DELETE CASCADE
);

-- proj_rfi
CREATE TABLE IF NOT EXISTS ot.proj_rfi (
    tenant_code TEXT NOT NULL REFERENCES ot.tnnt_tenant(tenant_code) ON DELETE RESTRICT,
    project_id CHAR(21) NOT NULL,
    rfi_id CHAR(21) PRIMARY KEY DEFAULT nanoid(),
    version INT NOT NULL DEFAULT 1, -- from ot.sys_event.version
    ref_no TEXT NOT NULL,
    title TEXT NOT NULL, -- aka name
    discipline TEXT NOT NULL, -- architecture, structure, mechanical
    submit_date BIGINT DEFAULT NULL, -- date submitted
    target_date BIGINT DEFAULT NULL, -- target approval date
    assignee_user_id CHAR(21) DEFAULT NULL,
    status TEXT NOT NULL,
    is_closed BOOLEAN NOT NULL DEFAULT false,
    data JSONB DEFAULT NULL, --
    --
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_id CHAR(21) DEFAULT NULL,
    created_name TEXT DEFAULT NULL,
    created_time BIGINT DEFAULT (extract(epoch from CURRENT_TIMESTAMP) * 1000),
    updated_id CHAR(21) DEFAULT NULL,
    updated_name TEXT DEFAULT NULL,
    updated_time BIGINT DEFAULT NULL,
    --
    FOREIGN KEY(project_id) REFERENCES ot.tnnt_project(project_id) ON DELETE CASCADE
);


-- ============= many-to-many ========================
-- -- groups_members
-- CREATE TABLE IF NOT EXISTS ot.proj_groups_members(
--     tenant_code TEXT NOT NULL REFERENCES ot.tnnt_tenant(tenant_code) ON DELETE RESTRICT,
--     stream_id CHAR(21) PRIMARY KEY DEFAULT nanoid(),
--     project_id CHAR(21) NOT NULL,
--     group_id CHAR(21) NOT NULL,
--     member_id CHAR(21) NOT NULL,
--     user_id CHAR(21) NOT NULL,
--     --
--     UNIQUE (project_id, group_id, member_id),
--     FOREIGN KEY(project_id) REFERENCES ot.tnnt_project(project_id) ON DELETE CASCADE,
--     FOREIGN KEY(group_id) REFERENCES ot.proj_group(group_id) ON DELETE CASCADE,
--     FOREIGN KEY(member_id) REFERENCES ot.proj_member(member_id) ON DELETE CASCADE,
--     FOREIGN KEY(user_id) REFERENCES ot.app_user(user_id) ON DELETE CASCADE,
--     --
--     is_active BOOLEAN NOT NULL DEFAULT true,
--     created_id CHAR(21) DEFAULT NULL,
--     created_name TEXT DEFAULT NULL,
--     created_time BIGINT DEFAULT (extract(epoch from CURRENT_TIMESTAMP) * 1000)
-- );

-- -- proj_groups_users
-- CREATE TABLE IF NOT EXISTS ot.proj_groups_users(
--     stream_id CHAR(21) PRIMARY KEY DEFAULT nanoid(),
--     tenant_code TEXT NOT NULL REFERENCES ot.tnnt_tenant(tenant_code) ON DELETE RESTRICT,
--     project_id CHAR(21) NOT NULL,
--     group_id CHAR(21) NOT NULL,
--     user_id CHAR(21) NOT NULL,
--     role TEXT NOT NULL, -- 'proj_group_admin', 'proj_group_user'
--     --
--     is_active BOOLEAN NOT NULL DEFAULT true,
--     created_id CHAR(21) DEFAULT NULL,
--     created_name TEXT DEFAULT NULL,
--     created_time BIGINT DEFAULT (extract(epoch from CURRENT_TIMESTAMP) * 1000),
--     --
--     UNIQUE (project_id, group_id, user_id),
--     FOREIGN KEY(project_id) REFERENCES ot.tnnt_project(project_id) ON DELETE CASCADE,
--     FOREIGN KEY(group_id) REFERENCES ot.proj_group(group_id) ON DELETE CASCADE,
--     FOREIGN KEY(user_id) REFERENCES ot.app_user(user_id) ON DELETE CASCADE
-- );


-- proj_progress_items_files
CREATE TABLE IF NOT EXISTS ot.proj_progress_items_files(
    tenant_code TEXT NOT NULL REFERENCES ot.tnnt_tenant(tenant_code) ON DELETE RESTRICT,
    stream_id CHAR(21) PRIMARY KEY DEFAULT nanoid(),
    project_id CHAR(21) NOT NULL,
    progress_item_id CHAR(21) NOT NULL,
    file_id CHAR(21) NOT NULL,
    --
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_id CHAR(21) DEFAULT NULL,
    created_name TEXT DEFAULT NULL,
    created_time BIGINT DEFAULT (extract(epoch from CURRENT_TIMESTAMP) * 1000),
    --
    UNIQUE (project_id, progress_item_id, file_id),
    FOREIGN KEY(progress_item_id) REFERENCES ot.proj_progress_item(progress_item_id) ON DELETE CASCADE,
    FOREIGN KEY(file_id) REFERENCES ot.proj_file(file_id) ON DELETE CASCADE
);

-- proj_progress_groups_files
CREATE TABLE IF NOT EXISTS ot.proj_progress_groups_files(
    tenant_code TEXT NOT NULL REFERENCES ot.tnnt_tenant(tenant_code) ON DELETE RESTRICT,
    stream_id CHAR(21) PRIMARY KEY DEFAULT nanoid(),
    project_id CHAR(21) NOT NULL,
    progress_group_id CHAR(21) NOT NULL,
    file_id CHAR(21) NOT NULL,
    --
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_id CHAR(21) DEFAULT NULL,
    created_name TEXT DEFAULT NULL,
    created_time BIGINT DEFAULT (extract(epoch from CURRENT_TIMESTAMP) * 1000),
    --
    UNIQUE (project_id, progress_group_id, file_id),
    FOREIGN KEY(progress_group_id) REFERENCES ot.proj_progress_group(progress_group_id) ON DELETE CASCADE,
    FOREIGN KEY(file_id) REFERENCES ot.proj_file(file_id) ON DELETE CASCADE
);


-- proj_import
CREATE TABLE IF NOT EXISTS ot.proj_import (
    tenant_code TEXT NOT NULL REFERENCES ot.tnnt_tenant(tenant_code) ON DELETE RESTRICT,
    project_id CHAR(21) NOT NULL,
    import_id CHAR(21) PRIMARY KEY DEFAULT nanoid(),
    project_name TEXT NOT NULL,
    project_code TEXT NOT NULL,
    data_type TEXT NOT NULL, -- IFC, CSV, JSON, APP, ...
    version TEXT DEFAULT NULL,
    data JSONB DEFAULT NULL, -- [{...},{...}] ordered info
    --
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_id CHAR(21) DEFAULT NULL,
    created_name TEXT DEFAULT NULL,
    created_time BIGINT DEFAULT (extract(epoch from CURRENT_TIMESTAMP) * 1000),
    --
    FOREIGN KEY(project_id) REFERENCES ot.tnnt_project(project_id) ON DELETE CASCADE
);






-- ===========================================
-- Data
-- ===========================================
-- (1) SYS_ADMIN, SYS_USER,
-- (2) APP_ADMIN, APP_USER,
-- (3) PROJ_ADMIN, PROJ_MEMBER,
-- (4) GROUP_ADMIN, GROUP_MEMBER


-- ===========================================================================
-- User connected from NestJS dashboard
CREATE USER tenant WITH PASSWORD '7ORuP8MdiR5aLf8';
GRANT ALL ON SCHEMA ot TO tenant;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA ot TO tenant;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA ot TO tenant;

-- tenant
ALTER TABLE ot.tnnt_tenant ENABLE ROW LEVEL SECURITY;
ALTER TABLE ot.tnnt_tenant FORCE ROW LEVEL SECURITY;
--
CREATE POLICY tenant_isolation_policy ON ot.tnnt_tenant
USING (tenant_code = current_setting('ot.current_tenant_code'));

-- group
ALTER TABLE ot.tnnt_group ENABLE ROW LEVEL SECURITY;
ALTER TABLE ot.tnnt_group FORCE ROW LEVEL SECURITY;
--
CREATE POLICY group_isolation_policy ON ot.tnnt_group
USING (tenant_code = current_setting('ot.current_tenant_code'));

-- project
ALTER TABLE ot.tnnt_project ENABLE ROW LEVEL SECURITY;
ALTER TABLE ot.tnnt_project FORCE ROW LEVEL SECURITY;
--
CREATE POLICY project_isolation_policy ON ot.tnnt_project
USING (tenant_code = current_setting('ot.current_tenant_code'));

-- company
ALTER TABLE ot.tnnt_company ENABLE ROW LEVEL SECURITY;
ALTER TABLE ot.tnnt_company FORCE ROW LEVEL SECURITY;
--
CREATE POLICY company_isolation_policy ON ot.tnnt_company
USING (tenant_code = current_setting('ot.current_tenant_code'));

-- many-to-many -----------------------------
-- groups_users
ALTER TABLE ot.mn_groups_users ENABLE ROW LEVEL SECURITY;
ALTER TABLE ot.mn_groups_users FORCE ROW LEVEL SECURITY;
--
CREATE POLICY groups_users_isolation_policy ON ot.mn_groups_users
USING (tenant_code = current_setting('ot.current_tenant_code'));

-- tenants_users
ALTER TABLE ot.mn_tenants_users ENABLE ROW LEVEL SECURITY;
ALTER TABLE ot.mn_tenants_users FORCE ROW LEVEL SECURITY;
--
CREATE POLICY tenants_users_isolation_policy ON ot.mn_tenants_users
USING (tenant_code = current_setting('ot.current_tenant_code'));

-- tenants_groups
ALTER TABLE ot.mn_tenants_groups ENABLE ROW LEVEL SECURITY;
ALTER TABLE ot.mn_tenants_groups FORCE ROW LEVEL SECURITY;
--
CREATE POLICY tenants_groups_isolation_policy ON ot.mn_tenants_groups
USING (tenant_code = current_setting('ot.current_tenant_code'));

-- projects_services
ALTER TABLE ot.mn_projects_services ENABLE ROW LEVEL SECURITY;
ALTER TABLE ot.mn_projects_services FORCE ROW LEVEL SECURITY;
--
CREATE POLICY projects_services_isolation_policy ON ot.mn_projects_services
USING (tenant_code = current_setting('ot.current_tenant_code'));

-- projects_users
ALTER TABLE ot.mn_projects_users ENABLE ROW LEVEL SECURITY;
ALTER TABLE ot.mn_projects_users FORCE ROW LEVEL SECURITY;
--
CREATE POLICY projects_users_isolation_policy ON ot.mn_projects_users
USING (tenant_code = current_setting('ot.current_tenant_code'));

-- projects_groups
ALTER TABLE ot.mn_projects_groups ENABLE ROW LEVEL SECURITY;
ALTER TABLE ot.mn_projects_groups FORCE ROW LEVEL SECURITY;
--
CREATE POLICY projects_groups_isolation_policy ON ot.mn_projects_groups
USING (tenant_code = current_setting('ot.current_tenant_code'));

-- companies_users
ALTER TABLE ot.mn_companies_users ENABLE ROW LEVEL SECURITY;
ALTER TABLE ot.mn_companies_users FORCE ROW LEVEL SECURITY;
--
CREATE POLICY companies_users_isolation_policy ON ot.mn_companies_users
USING (tenant_code = current_setting('ot.current_tenant_code'));

-- companies_groups
ALTER TABLE ot.mn_companies_groups ENABLE ROW LEVEL SECURITY;
ALTER TABLE ot.mn_companies_groups FORCE ROW LEVEL SECURITY;
--
CREATE POLICY companies_groups_isolation_policy ON ot.mn_companies_groups
USING (tenant_code = current_setting('ot.current_tenant_code'));



-- -- proj_member
-- ALTER TABLE ot.proj_member ENABLE ROW LEVEL SECURITY;
-- ALTER TABLE ot.proj_member FORCE ROW LEVEL SECURITY;
-- --
-- CREATE POLICY proj_member_isolation_policy ON ot.proj_member
-- USING (tenant_code = current_setting('ot.current_tenant_code'));

-- -- proj_group
-- ALTER TABLE ot.proj_group ENABLE ROW LEVEL SECURITY;
-- ALTER TABLE ot.proj_group FORCE ROW LEVEL SECURITY;
-- --
-- CREATE POLICY proj_group_isolation_policy ON ot.proj_group
-- USING (tenant_code = current_setting('ot.current_tenant_code'));

-- -- proj_role
-- ALTER TABLE ot.proj_role ENABLE ROW LEVEL SECURITY;
-- ALTER TABLE ot.proj_role FORCE ROW LEVEL SECURITY;
-- --
-- CREATE POLICY proj_role_isolation_policy ON ot.proj_role
-- USING (tenant_code = current_setting('ot.current_tenant_code'));

-- -- proj_permission
-- ALTER TABLE ot.proj_permission ENABLE ROW LEVEL SECURITY;
-- ALTER TABLE ot.proj_permission FORCE ROW LEVEL SECURITY;
-- --
-- CREATE POLICY proj_permission_isolation_policy ON ot.proj_permission
-- USING (tenant_code = current_setting('ot.current_tenant_code'));

-- proj_location
ALTER TABLE ot.proj_location ENABLE ROW LEVEL SECURITY;
ALTER TABLE ot.proj_location FORCE ROW LEVEL SECURITY;
--
CREATE POLICY proj_location_isolation_policy ON ot.proj_location
USING (tenant_code = current_setting('ot.current_tenant_code'));

-- proj_ifc_element
ALTER TABLE ot.proj_ifc_element ENABLE ROW LEVEL SECURITY;
ALTER TABLE ot.proj_ifc_element FORCE ROW LEVEL SECURITY;
--
CREATE POLICY proj_ifc_element_isolation_policy ON ot.proj_ifc_element
USING (tenant_code = current_setting('ot.current_tenant_code'));

-- proj_file
ALTER TABLE ot.proj_file ENABLE ROW LEVEL SECURITY;
ALTER TABLE ot.proj_file FORCE ROW LEVEL SECURITY;
--
CREATE POLICY proj_file_isolation_policy ON ot.proj_file
USING (tenant_code = current_setting('ot.current_tenant_code'));

-- proj_report
ALTER TABLE ot.proj_report ENABLE ROW LEVEL SECURITY;
ALTER TABLE ot.proj_report FORCE ROW LEVEL SECURITY;
--
CREATE POLICY proj_report_isolation_policy ON ot.proj_report
USING (tenant_code = current_setting('ot.current_tenant_code'));

-- proj_drawing
ALTER TABLE ot.proj_drawing ENABLE ROW LEVEL SECURITY;
ALTER TABLE ot.proj_drawing FORCE ROW LEVEL SECURITY;
--
CREATE POLICY proj_drawing_isolation_policy ON ot.proj_drawing
USING (tenant_code = current_setting('ot.current_tenant_code'));

-- proj_image
ALTER TABLE ot.proj_image ENABLE ROW LEVEL SECURITY;
ALTER TABLE ot.proj_image FORCE ROW LEVEL SECURITY;
--
CREATE POLICY proj_image_isolation_policy ON ot.proj_image
USING (tenant_code = current_setting('ot.current_tenant_code'));

-- proj_tag
ALTER TABLE ot.proj_tag ENABLE ROW LEVEL SECURITY;
ALTER TABLE ot.proj_tag FORCE ROW LEVEL SECURITY;
--
CREATE POLICY proj_tag_isolation_policy ON ot.proj_tag
USING (tenant_code = current_setting('ot.current_tenant_code'));

-- proj_progress_group
ALTER TABLE ot.proj_progress_group ENABLE ROW LEVEL SECURITY;
ALTER TABLE ot.proj_progress_group FORCE ROW LEVEL SECURITY;
--
CREATE POLICY proj_progress_group_isolation_policy ON ot.proj_progress_group
USING (tenant_code = current_setting('ot.current_tenant_code'));

-- proj_progress_item
ALTER TABLE ot.proj_progress_item ENABLE ROW LEVEL SECURITY;
ALTER TABLE ot.proj_progress_item FORCE ROW LEVEL SECURITY;
--
CREATE POLICY proj_progress_item_isolation_policy ON ot.proj_progress_item
USING (tenant_code = current_setting('ot.current_tenant_code'));

-- proj_progress_process_template
ALTER TABLE ot.proj_progress_process_template ENABLE ROW LEVEL SECURITY;
ALTER TABLE ot.proj_progress_process_template FORCE ROW LEVEL SECURITY;
--
CREATE POLICY proj_progress_process_template_isolation_policy ON ot.proj_progress_process_template
USING (tenant_code = current_setting('ot.current_tenant_code'));

-- proj_progress_process
ALTER TABLE ot.proj_progress_process ENABLE ROW LEVEL SECURITY;
ALTER TABLE ot.proj_progress_process FORCE ROW LEVEL SECURITY;
--
CREATE POLICY proj_progress_process_isolation_policy ON ot.proj_progress_process
USING (tenant_code = current_setting('ot.current_tenant_code'));

-- proj_progress_workflow
ALTER TABLE ot.proj_progress_workflow ENABLE ROW LEVEL SECURITY;
ALTER TABLE ot.proj_progress_workflow FORCE ROW LEVEL SECURITY;
--
CREATE POLICY proj_progress_workflow_isolation_policy ON ot.proj_progress_workflow
USING (tenant_code = current_setting('ot.current_tenant_code'));

-- proj_progress_task
ALTER TABLE ot.proj_progress_task ENABLE ROW LEVEL SECURITY;
ALTER TABLE ot.proj_progress_task FORCE ROW LEVEL SECURITY;
--
CREATE POLICY proj_progress_task_isolation_policy ON ot.proj_progress_task
USING (tenant_code = current_setting('ot.current_tenant_code'));

-- proj_progress_task_update
ALTER TABLE ot.proj_progress_task_update ENABLE ROW LEVEL SECURITY;
ALTER TABLE ot.proj_progress_task_update FORCE ROW LEVEL SECURITY;
--
CREATE POLICY proj_progress_task_update_isolation_policy ON ot.proj_progress_task_update
USING (tenant_code = current_setting('ot.current_tenant_code'));

-- proj_inspection_template
ALTER TABLE ot.proj_inspection_template ENABLE ROW LEVEL SECURITY;
ALTER TABLE ot.proj_inspection_template FORCE ROW LEVEL SECURITY;
--
CREATE POLICY proj_inspection_template_isolation_policy ON ot.proj_inspection_template
USING (tenant_code = current_setting('ot.current_tenant_code'));

-- proj_assignment
ALTER TABLE ot.proj_assignment ENABLE ROW LEVEL SECURITY;
ALTER TABLE ot.proj_assignment FORCE ROW LEVEL SECURITY;
--
CREATE POLICY proj_assignment_isolation_policy ON ot.proj_assignment
USING (tenant_code = current_setting('ot.current_tenant_code'));

-- proj_inspection
ALTER TABLE ot.proj_inspection ENABLE ROW LEVEL SECURITY;
ALTER TABLE ot.proj_inspection FORCE ROW LEVEL SECURITY;
--
CREATE POLICY proj_inspection_isolation_policy ON ot.proj_inspection
USING (tenant_code = current_setting('ot.current_tenant_code'));

-- proj_inspection_info_update
ALTER TABLE ot.proj_inspection_info_update ENABLE ROW LEVEL SECURITY;
ALTER TABLE ot.proj_inspection_info_update FORCE ROW LEVEL SECURITY;
--
CREATE POLICY proj_inspection_info_update_isolation_policy ON ot.proj_inspection_info_update
USING (tenant_code = current_setting('ot.current_tenant_code'));

-- proj_inspection_assignment_update
ALTER TABLE ot.proj_inspection_assignment_update ENABLE ROW LEVEL SECURITY;
ALTER TABLE ot.proj_inspection_assignment_update FORCE ROW LEVEL SECURITY;
--
CREATE POLICY proj_inspection_assignment_isolation_policy ON ot.proj_inspection_assignment_update
USING (tenant_code = current_setting('ot.current_tenant_code'));

-- proj_inspection_update
ALTER TABLE ot.proj_inspection_update ENABLE ROW LEVEL SECURITY;
ALTER TABLE ot.proj_inspection_update FORCE ROW LEVEL SECURITY;
--
CREATE POLICY proj_inspection_update_isolation_policy ON ot.proj_inspection_update
USING (tenant_code = current_setting('ot.current_tenant_code'));

-- proj_inspection_step
ALTER TABLE ot.proj_inspection_step ENABLE ROW LEVEL SECURITY;
ALTER TABLE ot.proj_inspection_step FORCE ROW LEVEL SECURITY;
--
CREATE POLICY proj_inspection_step_isolation_policy ON ot.proj_inspection_step
USING (tenant_code = current_setting('ot.current_tenant_code'));

-- proj_form_template
ALTER TABLE ot.proj_form_template ENABLE ROW LEVEL SECURITY;
ALTER TABLE ot.proj_form_template FORCE ROW LEVEL SECURITY;
--
CREATE POLICY proj_form_template_isolation_policy ON ot.proj_form_template
USING (tenant_code = current_setting('ot.current_tenant_code'));

-- proj_form
ALTER TABLE ot.proj_form ENABLE ROW LEVEL SECURITY;
ALTER TABLE ot.proj_form FORCE ROW LEVEL SECURITY;
--
CREATE POLICY proj_form_isolation_policy ON ot.proj_form
USING (tenant_code = current_setting('ot.current_tenant_code'));

-- proj_form_update
ALTER TABLE ot.proj_form_update ENABLE ROW LEVEL SECURITY;
ALTER TABLE ot.proj_form_update FORCE ROW LEVEL SECURITY;
--
CREATE POLICY proj_form_update_isolation_policy ON ot.proj_form_update
USING (tenant_code = current_setting('ot.current_tenant_code'));

-- proj_progress_items_files
ALTER TABLE ot.proj_progress_items_files ENABLE ROW LEVEL SECURITY;
ALTER TABLE ot.proj_progress_items_files FORCE ROW LEVEL SECURITY;
--
CREATE POLICY proj_progress_items_files_isolation_policy ON ot.proj_progress_items_files
USING (tenant_code = current_setting('ot.current_tenant_code'));

-- proj_progress_groups_files
ALTER TABLE ot.proj_progress_groups_files ENABLE ROW LEVEL SECURITY;
ALTER TABLE ot.proj_progress_groups_files FORCE ROW LEVEL SECURITY;
--
CREATE POLICY proj_progress_groups_files_isolation_policy ON ot.proj_progress_groups_files
USING (tenant_code = current_setting('ot.current_tenant_code'));

-- proj_import
ALTER TABLE ot.proj_import ENABLE ROW LEVEL SECURITY;
ALTER TABLE ot.proj_import FORCE ROW LEVEL SECURITY;
--
CREATE POLICY proj_import_isolation_policy ON ot.proj_import
USING (tenant_code = current_setting('ot.current_tenant_code'));



--
INSERT INTO ot.sys_role(role_id) VALUES('portfolio_read_write');
INSERT INTO ot.sys_role(role_id) VALUES('portfolio_read_only');
INSERT INTO ot.sys_role(role_id) VALUES('tenant_read_write');
INSERT INTO ot.sys_role(role_id) VALUES('tenant_read_only');
INSERT INTO ot.sys_role(role_id) VALUES('project_read_write');
INSERT INTO ot.sys_role(role_id) VALUES('project_read_only');
INSERT INTO ot.sys_role(role_id) VALUES('company_read_write');
INSERT INTO ot.sys_role(role_id) VALUES('company_read_only');
INSERT INTO ot.sys_role(role_id) VALUES('group_read_write');
INSERT INTO ot.sys_role(role_id) VALUES('group_read_only');

-- Sys-scope
INSERT INTO ot.sys_permission(permission_id) VALUES('READ_SUPERUSER');
INSERT INTO ot.sys_permission(permission_id) VALUES('CREATE_SUPERUSER');
INSERT INTO ot.sys_permission(permission_id) VALUES('UPDATE_SUPERUSER');
INSERT INTO ot.sys_permission(permission_id) VALUES('DELETE_SUPERUSER');

INSERT INTO ot.sys_permission(permission_id) VALUES('READ_ROLE');
INSERT INTO ot.sys_permission(permission_id) VALUES('CREATE_ROLE');
INSERT INTO ot.sys_permission(permission_id) VALUES('UPDATE_ROLE');
INSERT INTO ot.sys_permission(permission_id) VALUES('DELETE_ROLE');

INSERT INTO ot.sys_permission(permission_id) VALUES('READ_PERMISSION');
INSERT INTO ot.sys_permission(permission_id) VALUES('CREATE_PERMISSION');
INSERT INTO ot.sys_permission(permission_id) VALUES('UPDATE_PERMISSION');
INSERT INTO ot.sys_permission(permission_id) VALUES('DELETE_PERMISSION');

-- App-scope
INSERT INTO ot.sys_permission(permission_id) VALUES('READ_USER');
INSERT INTO ot.sys_permission(permission_id) VALUES('CREATE_USER');
INSERT INTO ot.sys_permission(permission_id) VALUES('UPDATE_USER');
INSERT INTO ot.sys_permission(permission_id) VALUES('DELETE_USER');

INSERT INTO ot.sys_permission(permission_id) VALUES('READ_PORTFOLIO');
INSERT INTO ot.sys_permission(permission_id) VALUES('CREATE_PORTFOLIO');
INSERT INTO ot.sys_permission(permission_id) VALUES('UPDATE_PORTFOLIO');
INSERT INTO ot.sys_permission(permission_id) VALUES('DELETE_PORTFOLIO');

-- Tenant-scope
INSERT INTO ot.sys_permission(permission_id) VALUES('READ_TENANT');
INSERT INTO ot.sys_permission(permission_id) VALUES('CREATE_TENANT');
INSERT INTO ot.sys_permission(permission_id) VALUES('UPDATE_TENANT');
INSERT INTO ot.sys_permission(permission_id) VALUES('DELETE_TENANT');

INSERT INTO ot.sys_permission(permission_id) VALUES('READ_GROUP');
INSERT INTO ot.sys_permission(permission_id) VALUES('CREATE_GROUP');
INSERT INTO ot.sys_permission(permission_id) VALUES('UPDATE_GROUP');
INSERT INTO ot.sys_permission(permission_id) VALUES('DELETE_GROUP');

INSERT INTO ot.sys_permission(permission_id) VALUES('READ_PROJECT');
INSERT INTO ot.sys_permission(permission_id) VALUES('CREATE_PROJECT');
INSERT INTO ot.sys_permission(permission_id) VALUES('UPDATE_PROJECT');
INSERT INTO ot.sys_permission(permission_id) VALUES('DELETE_PROJECT');

INSERT INTO ot.sys_permission(permission_id) VALUES('READ_COMPANY');
INSERT INTO ot.sys_permission(permission_id) VALUES('CREATE_COMPANY');
INSERT INTO ot.sys_permission(permission_id) VALUES('UPDATE_COMPANY');
INSERT INTO ot.sys_permission(permission_id) VALUES('DELETE_COMPANY');

INSERT INTO ot.sys_permission(permission_id) VALUES('READ_PORTFOLIOS_USERS');
INSERT INTO ot.sys_permission(permission_id) VALUES('CREATE_PORTFOLIOS_USERS');
INSERT INTO ot.sys_permission(permission_id) VALUES('DELETE_PORTFOLIOS_USERS');

INSERT INTO ot.sys_permission(permission_id) VALUES('READ_PORTFOLIOS_PROJECTS');
INSERT INTO ot.sys_permission(permission_id) VALUES('CREATE_PORTFOLIOS_PROJECTS');
INSERT INTO ot.sys_permission(permission_id) VALUES('DELETE_PORTFOLIOS_PROJECTS');

INSERT INTO ot.sys_permission(permission_id) VALUES('READ_GROUPS_USERS');
INSERT INTO ot.sys_permission(permission_id) VALUES('CREATE_GROUPS_USERS');
INSERT INTO ot.sys_permission(permission_id) VALUES('DELETE_GROUPS_USERS');

INSERT INTO ot.sys_permission(permission_id) VALUES('READ_TENANTS_USERS');
INSERT INTO ot.sys_permission(permission_id) VALUES('CREATE_TENANTS_USERS');
INSERT INTO ot.sys_permission(permission_id) VALUES('DELETE_TENANTS_USERS');

INSERT INTO ot.sys_permission(permission_id) VALUES('READ_TENANTS_GROUPS');
INSERT INTO ot.sys_permission(permission_id) VALUES('CREATE_TENANTS_GROUPS');
INSERT INTO ot.sys_permission(permission_id) VALUES('DELETE_TENANTS_GROUPS');

INSERT INTO ot.sys_permission(permission_id) VALUES('READ_PROJECTS_USERS');
INSERT INTO ot.sys_permission(permission_id) VALUES('CREATE_PROJECTS_USERS');
INSERT INTO ot.sys_permission(permission_id) VALUES('DELETE_PROJECTS_USERS');

INSERT INTO ot.sys_permission(permission_id) VALUES('READ_PROJECTS_GROUPS');
INSERT INTO ot.sys_permission(permission_id) VALUES('CREATE_PROJECTS_GROUPS');
INSERT INTO ot.sys_permission(permission_id) VALUES('DELETE_PROJECTS_GROUPS');

INSERT INTO ot.sys_permission(permission_id) VALUES('READ_COMPANIES_USERS');
INSERT INTO ot.sys_permission(permission_id) VALUES('CREATE_COMPANIES_USERS');
INSERT INTO ot.sys_permission(permission_id) VALUES('DELETE_COMPANIES_USERS');

INSERT INTO ot.sys_permission(permission_id) VALUES('READ_COMPANIES_GROUPS');
INSERT INTO ot.sys_permission(permission_id) VALUES('CREATE_COMPANIES_GROUPS');
INSERT INTO ot.sys_permission(permission_id) VALUES('DELETE_COMPANIES_GROUPS');










-- insert into ot.tnnt_tenant(tenant_id, name, status, tier) values('jtc', 'JTC', 'active', 'professional');
-- insert into ot.tnnt_tenant(tenant_id, name, status, tier) values('hdb', 'HDB', 'active', 'essential');


-- insert into ot.tnnt_tenant(tenant_id, name, status, tier) values('org-01', 'ORG-01', 'active', 'essential');
-- insert into ot.tnnt_tenant(tenant_id, name, status, tier) values('org-02', 'ORG-02', 'suspended', 'professional');
-- insert into ot.tnnt_tenant(tenant_id, name, status, tier) values('org-03', 'ORG-03', 'disabled', 'enterprise');
-- select * from ot.tnnt_tenant;

-- insert into ot.app_user(user_id, tenant_id, email, name) values('org-user-1', 'org-01', 'org-user-1@x.com', 'USER 1');
-- insert into ot.app_user(user_id, tenant_id, email, name) values('org-user-2', 'org-01', 'org-user-2@x.com', 'USER 2');
-- insert into ot.app_user(user_id, tenant_id, email, name) values('org-user-3', 'org-02', 'org-user-3@x.com', 'USER 3');
-- insert into ot.app_user(user_id, tenant_id, email, name) values('org-user-4', 'org-02', 'org-user-4@x.com', 'USER 4');
-- insert into ot.app_user(user_id, tenant_id, email, name) values('org-user-5', 'org-03', 'org-user-5@x.com', 'USER 5');
-- insert into ot.app_user(user_id, tenant_id, email, name) values('org-user-6', 'org-03', 'org-user-6@x.com', 'USER 6');
-- select * from ot.app_user;

-- select current_user
-- SELECT set_config('ot.current_tenant_id', 'hdb', FALSE);
-- SET ot.current_tenant_id = 'hdb'
-- SHOW ot.current_tenant_id
-- SELECT current_setting('ot.current_tenant_id')

-- ALTER TABLE ot.tnnt_tenant ENABLE ROW LEVEL SECURITY;
-- ALTER TABLE ot.tnnt_tenant FORCE ROW LEVEL SECURITY;

-- CREATE POLICY tenant_isolation_policy ON ot.tnnt_tenant
-- USING (tenant_id = current_setting('ot.current_tenant_id'));

-- CREATE POLICY tenant_isolation_policy ON ot.tnnt_tenant
-- USING (false);

-- DROP POLICY IF EXISTS tenant_isolation_policy on ot.tnnt_tenant;
-- ALTER TABLE ot.tnnt_tenant DISABLE ROW LEVEL SECURITY;
