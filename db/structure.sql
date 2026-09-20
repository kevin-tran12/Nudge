SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: vector; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public VERSION '0.8.5';


--
-- Name: EXTENSION vector; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION vector IS 'vector data type and ivfflat and hnsw access methods';


--
-- Name: db04_encryption_context_immutable(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.db04_encryption_context_immutable() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog'
    AS $$
BEGIN
  IF NEW.encryption_context IS DISTINCT FROM OLD.encryption_context
  THEN RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='encryption_context_immutable'; END IF;
  RETURN NEW;
END $$;


--
-- Name: db04_fact_definition_guard(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.db04_fact_definition_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog'
    AS $$
BEGIN
  IF TG_OP='UPDATE' AND (NEW.id,NEW.key,NEW.data_type,NEW.unit_dimension,NEW.canonical_unit,NEW.allowed_operators,
      NEW.allowed_operators_schema_version,NEW.allowed_values_schema,NEW.allowed_values_schema_version,
      NEW.hard_eligibility_supported,NEW.version,NEW.created_at) IS DISTINCT FROM
     (OLD.id,OLD.key,OLD.data_type,OLD.unit_dimension,OLD.canonical_unit,OLD.allowed_operators,
      OLD.allowed_operators_schema_version,OLD.allowed_values_schema,OLD.allowed_values_schema_version,
      OLD.hard_eligibility_supported,OLD.version,OLD.created_at)
  THEN RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='fact_definition_interpretation_immutable'; END IF;
  IF pg_catalog.jsonb_typeof(NEW.allowed_operators)<>'array'
  THEN RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='fact_definition_operators_invalid'; END IF;
  IF EXISTS (SELECT 1 FROM pg_catalog.jsonb_array_elements(NEW.allowed_operators) e WHERE pg_catalog.jsonb_typeof(e)<>'string' OR nullif(pg_catalog.btrim(e#>>'{}'),'') IS NULL) OR
     (SELECT pg_catalog.count(*) FROM pg_catalog.jsonb_array_elements_text(NEW.allowed_operators)) <>
     (SELECT pg_catalog.count(DISTINCT x) FROM pg_catalog.jsonb_array_elements_text(NEW.allowed_operators) x)
  THEN RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='fact_definition_operators_invalid'; END IF;
  IF NEW.data_type='enum' THEN
    IF pg_catalog.jsonb_typeof(NEW.allowed_values_schema)<>'object' OR NOT (NEW.allowed_values_schema ? 'enum') OR
       (SELECT pg_catalog.count(*) FROM pg_catalog.jsonb_object_keys(NEW.allowed_values_schema))<>1 OR
       pg_catalog.jsonb_typeof(NEW.allowed_values_schema->'enum')<>'array' OR pg_catalog.jsonb_array_length(NEW.allowed_values_schema->'enum')=0
    THEN RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='fact_definition_enum_invalid'; END IF;
    IF EXISTS (SELECT 1 FROM pg_catalog.jsonb_array_elements(NEW.allowed_values_schema->'enum') e WHERE pg_catalog.jsonb_typeof(e)<>'string' OR pg_catalog.octet_length(e#>>'{}') > 1024) OR
       (SELECT pg_catalog.count(*) FROM pg_catalog.jsonb_array_elements_text(NEW.allowed_values_schema->'enum')) <>
       (SELECT pg_catalog.count(DISTINCT x) FROM pg_catalog.jsonb_array_elements_text(NEW.allowed_values_schema->'enum') x)
    THEN RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='fact_definition_enum_invalid'; END IF;
  END IF;
  RETURN NEW;
END $$;


--
-- Name: db04_latest_observation_validate(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.db04_latest_observation_validate() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog'
    AS $$
DECLARE o record; expected_kind text; expected_external text;
BEGIN
  IF NEW.latest_observation_id IS NULL THEN RETURN NEW; END IF;
  IF TG_TABLE_NAME='supplier_products' THEN expected_kind:='product'; expected_external:=NEW.external_product_id;
  ELSE expected_kind:='variant'; expected_external:=NEW.external_variant_id; END IF;
  SELECT resource_kind,external_resource_id INTO o FROM public.supplier_observations
    WHERE id=NEW.latest_observation_id AND supplier_id=NEW.supplier_id FOR KEY SHARE;
  IF NOT FOUND OR o.resource_kind<>expected_kind OR o.external_resource_id<>expected_external
  THEN RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='latest_observation_identity_mismatch'; END IF;
  RETURN NEW;
END $$;


--
-- Name: db04_product_fact_validate(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.db04_product_fact_validate() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog'
    AS $$
DECLARE d public.fact_definitions%ROWTYPE; valid_enum boolean;
BEGIN
  SELECT * INTO d FROM public.fact_definitions WHERE id=NEW.fact_definition_id FOR KEY SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='23503', MESSAGE='product_fact_definition_missing'; END IF;
  IF (d.data_type='boolean' AND NEW.boolean_value IS NULL) OR
     (d.data_type='integer' AND NEW.integer_value IS NULL) OR
     (d.data_type IN ('decimal','measurement') AND NEW.decimal_value IS NULL) OR
     (d.data_type IN ('text','enum') AND NEW.text_value IS NULL) OR
     (d.data_type='json' AND NEW.json_value IS NULL)
  THEN RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='product_fact_definition_mismatch'; END IF;
  IF d.data_type='measurement' AND NEW.canonical_unit IS DISTINCT FROM d.canonical_unit
  THEN RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='product_fact_unit_mismatch'; END IF;
  IF d.data_type<>'measurement' AND NEW.canonical_unit IS NOT NULL
  THEN RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='product_fact_unit_mismatch'; END IF;
  IF d.data_type='enum' THEN
    SELECT EXISTS (SELECT 1 FROM pg_catalog.jsonb_array_elements_text(d.allowed_values_schema->'enum') x WHERE x=NEW.text_value) INTO valid_enum;
    IF NOT valid_enum THEN RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='product_fact_enum_mismatch'; END IF;
  END IF;
  RETURN NEW;
END $$;


--
-- Name: db04_supplier_observation_guard(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.db04_supplier_observation_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog'
    AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='supplier_observation_delete_denied'; END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.purged_at IS NOT NULL THEN RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='supplier_observation_purged_at_managed'; END IF;
    RETURN NEW;
  END IF;
  IF (NEW.id,NEW.supplier_id,NEW.resource_kind,NEW.external_resource_id,NEW.provider_request_id,NEW.endpoint_key,
      NEW.adapter_version,NEW.payload_schema_version,NEW.payload_sha256,NEW.observed_at,NEW.received_at,NEW.created_at,
      NEW.encryption_context) IS DISTINCT FROM
     (OLD.id,OLD.supplier_id,OLD.resource_kind,OLD.external_resource_id,OLD.provider_request_id,OLD.endpoint_key,
      OLD.adapter_version,OLD.payload_schema_version,OLD.payload_sha256,OLD.observed_at,OLD.received_at,OLD.created_at,
      OLD.encryption_context)
  THEN RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='supplier_observation_immutable'; END IF;
  IF NEW.purge_after > OLD.purge_after THEN RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='supplier_observation_deadline_extension_denied'; END IF;
  IF NEW.purged_at IS DISTINCT FROM OLD.purged_at
  THEN RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='supplier_observation_purged_at_managed'; END IF;
  IF OLD.purged_at IS NOT NULL AND (NEW.purged_at IS DISTINCT FROM OLD.purged_at OR NEW.payload_ciphertext IS NOT NULL OR NEW.payload_json IS NOT NULL)
  THEN RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='supplier_observation_restore_denied'; END IF;
  IF OLD.purged_at IS NULL AND NEW.payload_ciphertext IS NULL AND NEW.payload_json IS NULL THEN
    IF pg_catalog.statement_timestamp() < NEW.purge_after
    THEN RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='supplier_observation_purge_too_early'; END IF;
    NEW.purged_at := pg_catalog.statement_timestamp();
  ELSIF OLD.payload_json IS DISTINCT FROM NEW.payload_json THEN
    RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='supplier_observation_json_replacement_denied';
  END IF;
  RETURN NEW;
END $$;


--
-- Name: nudge_prevent_execution_mode_change(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.nudge_prevent_execution_mode_change() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog'
    AS $$
BEGIN
  IF NEW.execution_mode IS DISTINCT FROM OLD.execution_mode THEN
    RAISE EXCEPTION USING
      ERRCODE = '23514',
      MESSAGE = format('%I.execution_mode is immutable', TG_TABLE_NAME);
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: nudge_prevent_row_mutation(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.nudge_prevent_row_mutation() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog'
    AS $$
BEGIN
  RAISE EXCEPTION USING
    ERRCODE = '23514',
    MESSAGE = format('%I rows are immutable', TG_TABLE_NAME);
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: agent_provider_sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agent_provider_sessions (
    id bigint NOT NULL,
    ai_access_grant_id bigint NOT NULL,
    shopping_session_id bigint NOT NULL,
    provider text NOT NULL,
    provider_session_ref_ciphertext text,
    provider_session_ref_digest bytea,
    digest_key_version smallint,
    status text NOT NULL,
    started_at timestamp(6) with time zone NOT NULL,
    ended_at timestamp(6) with time zone,
    last_event_at timestamp(6) with time zone,
    termination_reason text,
    lock_version integer DEFAULT 0 NOT NULL,
    encryption_context uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT agent_provider_sessions_digest_key_version_check CHECK (((digest_key_version IS NULL) OR (digest_key_version > 0))),
    CONSTRAINT agent_provider_sessions_end_time_check CHECK (((ended_at IS NULL) OR (ended_at >= started_at))),
    CONSTRAINT agent_provider_sessions_lock_version_check CHECK ((lock_version >= 0)),
    CONSTRAINT agent_provider_sessions_provider_check CHECK ((provider = 'elevenlabs'::text)),
    CONSTRAINT agent_provider_sessions_ref_digest_length_check CHECK (((provider_session_ref_digest IS NULL) OR (octet_length(provider_session_ref_digest) = 32))),
    CONSTRAINT agent_provider_sessions_ref_pair_check CHECK ((((provider_session_ref_ciphertext IS NULL) AND (provider_session_ref_digest IS NULL) AND (digest_key_version IS NULL)) OR ((provider_session_ref_ciphertext IS NOT NULL) AND (provider_session_ref_digest IS NOT NULL) AND (digest_key_version IS NOT NULL)))),
    CONSTRAINT agent_provider_sessions_status_check CHECK ((status = ANY (ARRAY['starting'::text, 'active'::text, 'ended'::text, 'terminated'::text, 'failed'::text])))
);


--
-- Name: agent_provider_sessions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.agent_provider_sessions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: agent_provider_sessions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.agent_provider_sessions_id_seq OWNED BY public.agent_provider_sessions.id;


--
-- Name: agent_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agent_runs (
    id bigint NOT NULL,
    public_id uuid DEFAULT gen_random_uuid() NOT NULL,
    shopping_session_id bigint NOT NULL,
    ai_access_grant_id bigint,
    agent_provider_session_id bigint,
    correlation_id uuid NOT NULL,
    status text DEFAULT 'queued'::text NOT NULL,
    provider text NOT NULL,
    model_ref text,
    input_tokens integer,
    output_tokens integer,
    cost_microunits bigint,
    latency_ms integer,
    started_at timestamp(6) with time zone,
    completed_at timestamp(6) with time zone,
    lease_owner text,
    lease_token uuid,
    lease_expires_at timestamp(6) with time zone,
    purge_after timestamp(6) with time zone NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT agent_runs_completion_check CHECK (((completed_at IS NULL) OR (started_at IS NULL) OR (completed_at >= started_at))),
    CONSTRAINT agent_runs_cost_check CHECK (((cost_microunits IS NULL) OR (cost_microunits >= 0))),
    CONSTRAINT agent_runs_input_tokens_check CHECK (((input_tokens IS NULL) OR (input_tokens >= 0))),
    CONSTRAINT agent_runs_latency_check CHECK (((latency_ms IS NULL) OR (latency_ms >= 0))),
    CONSTRAINT agent_runs_lease_pair_check CHECK ((((lease_owner IS NULL) AND (lease_token IS NULL) AND (lease_expires_at IS NULL)) OR ((lease_owner IS NOT NULL) AND (lease_token IS NOT NULL) AND (lease_expires_at IS NOT NULL)))),
    CONSTRAINT agent_runs_output_tokens_check CHECK (((output_tokens IS NULL) OR (output_tokens >= 0))),
    CONSTRAINT agent_runs_status_check CHECK ((status = ANY (ARRAY['queued'::text, 'running'::text, 'succeeded'::text, 'failed'::text, 'cancelled'::text, 'terminated'::text])))
);


--
-- Name: agent_runs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.agent_runs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: agent_runs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.agent_runs_id_seq OWNED BY public.agent_runs.id;


--
-- Name: agent_tool_calls; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agent_tool_calls (
    id bigint NOT NULL,
    agent_run_id bigint NOT NULL,
    sequence bigint NOT NULL,
    tool_name text NOT NULL,
    tool_version text NOT NULL,
    request_hash bytea NOT NULL,
    input_projection jsonb DEFAULT '{}'::jsonb NOT NULL,
    input_schema_version smallint NOT NULL,
    output_projection jsonb,
    output_schema_version smallint,
    authorization_result text NOT NULL,
    idempotency_key text,
    status text NOT NULL,
    error_code text,
    started_at timestamp(6) with time zone NOT NULL,
    completed_at timestamp(6) with time zone,
    purge_after timestamp(6) with time zone NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT agent_tool_calls_completion_check CHECK (((completed_at IS NULL) OR (completed_at >= started_at))),
    CONSTRAINT agent_tool_calls_input_object_check CHECK ((jsonb_typeof(input_projection) = 'object'::text)),
    CONSTRAINT agent_tool_calls_input_version_check CHECK ((input_schema_version > 0)),
    CONSTRAINT agent_tool_calls_output_object_check CHECK (((output_projection IS NULL) OR (jsonb_typeof(output_projection) = 'object'::text))),
    CONSTRAINT agent_tool_calls_output_pair_check CHECK (((output_projection IS NULL) = (output_schema_version IS NULL))),
    CONSTRAINT agent_tool_calls_output_version_check CHECK (((output_schema_version IS NULL) OR (output_schema_version > 0))),
    CONSTRAINT agent_tool_calls_request_hash_check CHECK ((octet_length(request_hash) = 32)),
    CONSTRAINT agent_tool_calls_sequence_check CHECK ((sequence > 0))
);


--
-- Name: agent_tool_calls_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.agent_tool_calls_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: agent_tool_calls_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.agent_tool_calls_id_seq OWNED BY public.agent_tool_calls.id;


--
-- Name: ai_access_grants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ai_access_grants (
    id bigint NOT NULL,
    public_id uuid DEFAULT gen_random_uuid() NOT NULL,
    shopping_session_id bigint NOT NULL,
    grant_token_digest bytea NOT NULL,
    status text DEFAULT 'active'::text NOT NULL,
    disclosure_consent_record_id bigint NOT NULL,
    turnstile_verification_id bigint,
    verification_reason_snapshot text,
    issued_at timestamp(6) with time zone NOT NULL,
    expires_at timestamp(6) with time zone NOT NULL,
    revoked_at timestamp(6) with time zone,
    revocation_reason_code text,
    lock_version integer DEFAULT 0 NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT ai_access_grants_expiry_check CHECK (((expires_at > issued_at) AND (expires_at <= (issued_at + '01:00:00'::interval)))),
    CONSTRAINT ai_access_grants_lock_version_check CHECK ((lock_version >= 0)),
    CONSTRAINT ai_access_grants_status_check CHECK ((status = ANY (ARRAY['active'::text, 'expired'::text, 'revoked'::text, 'terminated'::text]))),
    CONSTRAINT ai_access_grants_token_digest_length_check CHECK ((octet_length(grant_token_digest) = 32))
);


--
-- Name: ai_access_grants_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.ai_access_grants_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: ai_access_grants_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.ai_access_grants_id_seq OWNED BY public.ai_access_grants.id;


--
-- Name: ar_internal_metadata; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ar_internal_metadata (
    key character varying NOT NULL,
    value character varying,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL
);


--
-- Name: catalog_media; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.catalog_media (
    id bigint NOT NULL,
    product_id bigint,
    product_variant_id bigint,
    supplier_observation_id bigint,
    kind text NOT NULL,
    original_url_ciphertext text,
    encryption_context uuid DEFAULT gen_random_uuid() NOT NULL,
    sanitized_url text,
    object_key text,
    mime_type text,
    width integer,
    height integer,
    checksum bytea,
    "position" integer DEFAULT 0 NOT NULL,
    status text NOT NULL,
    observed_at timestamp(6) with time zone,
    verified_at timestamp(6) with time zone,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT catalog_media_checksum_check CHECK (((checksum IS NULL) OR (octet_length(checksum) = 32))),
    CONSTRAINT catalog_media_height_check CHECK (((height IS NULL) OR (height >= 0))),
    CONSTRAINT catalog_media_kind_check CHECK ((kind = ANY (ARRAY['image'::text, 'video'::text]))),
    CONSTRAINT catalog_media_position_check CHECK (("position" >= 0)),
    CONSTRAINT catalog_media_subject_check CHECK ((num_nonnulls(product_id, product_variant_id) = 1)),
    CONSTRAINT catalog_media_width_check CHECK (((width IS NULL) OR (width >= 0)))
);


--
-- Name: catalog_media_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.catalog_media_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: catalog_media_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.catalog_media_id_seq OWNED BY public.catalog_media.id;


--
-- Name: categories; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.categories (
    id bigint NOT NULL,
    public_id uuid DEFAULT gen_random_uuid() NOT NULL,
    key text NOT NULL,
    name text NOT NULL,
    parent_id bigint,
    status text DEFAULT 'active'::text NOT NULL,
    "position" integer DEFAULT 0 NOT NULL,
    profile_version integer NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT categories_not_self_parent_check CHECK (((parent_id IS NULL) OR (parent_id <> id))),
    CONSTRAINT categories_position_check CHECK (("position" >= 0)),
    CONSTRAINT categories_profile_version_check CHECK ((profile_version >= 0))
);


--
-- Name: categories_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.categories_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: categories_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.categories_id_seq OWNED BY public.categories.id;


--
-- Name: clarification_decisions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.clarification_decisions (
    id bigint NOT NULL,
    shopping_session_id bigint NOT NULL,
    recommendation_run_id bigint,
    requirement_id bigint,
    candidate_reduction numeric(8,6) NOT NULL,
    importance numeric(8,6) NOT NULL,
    answerability numeric(8,6) NOT NULL,
    interaction_cost numeric(8,6) NOT NULL,
    computed_value numeric(12,6) NOT NULL,
    policy_version text NOT NULL,
    reason_code text NOT NULL,
    selected_message_id bigint,
    skipped_reason text,
    created_at timestamp(6) with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT clarification_decisions_answerability_check CHECK (((answerability >= (0)::numeric) AND (answerability <= (1)::numeric))),
    CONSTRAINT clarification_decisions_candidate_reduction_check CHECK (((candidate_reduction >= (0)::numeric) AND (candidate_reduction <= (1)::numeric))),
    CONSTRAINT clarification_decisions_importance_check CHECK (((importance >= (0)::numeric) AND (importance <= (1)::numeric))),
    CONSTRAINT clarification_decisions_interaction_cost_check CHECK (((interaction_cost >= (0)::numeric) AND (interaction_cost <= (1)::numeric))),
    CONSTRAINT clarification_decisions_selection_pair_check CHECK (((selected_message_id IS NULL) OR (skipped_reason IS NULL)))
);


--
-- Name: clarification_decisions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.clarification_decisions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: clarification_decisions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.clarification_decisions_id_seq OWNED BY public.clarification_decisions.id;


--
-- Name: consent_records; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.consent_records (
    id bigint NOT NULL,
    shopping_session_id bigint NOT NULL,
    user_id bigint,
    consent_kind text NOT NULL,
    policy_version text NOT NULL,
    decision text NOT NULL,
    scope_json jsonb DEFAULT '{}'::jsonb NOT NULL,
    scope_schema_version smallint NOT NULL,
    recorded_at timestamp(6) with time zone NOT NULL,
    withdrawn_at timestamp(6) with time zone,
    correlation_id uuid NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT consent_records_decision_check CHECK ((decision = ANY (ARRAY['accepted'::text, 'rejected'::text, 'customized'::text]))),
    CONSTRAINT consent_records_kind_check CHECK ((consent_kind = ANY (ARRAY['cookie_preferences'::text, 'ai_provider_disclosure'::text]))),
    CONSTRAINT consent_records_scope_object_check CHECK ((jsonb_typeof(scope_json) = 'object'::text)),
    CONSTRAINT consent_records_scope_version_check CHECK ((scope_schema_version > 0)),
    CONSTRAINT consent_records_withdrawal_check CHECK (((withdrawn_at IS NULL) OR (withdrawn_at >= recorded_at)))
);


--
-- Name: consent_records_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.consent_records_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: consent_records_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.consent_records_id_seq OWNED BY public.consent_records.id;


--
-- Name: eligibility_results; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.eligibility_results (
    id bigint NOT NULL,
    recommendation_candidate_id bigint NOT NULL,
    requirement_id bigint NOT NULL,
    outcome text NOT NULL,
    product_fact_id bigint,
    evaluator_version text NOT NULL,
    policy_version text NOT NULL,
    reason_code text NOT NULL,
    evaluated_at timestamp(6) with time zone NOT NULL,
    created_at timestamp(6) with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT eligibility_results_outcome_check CHECK ((outcome = ANY (ARRAY['pass'::text, 'fail'::text, 'unknown'::text])))
);


--
-- Name: eligibility_results_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.eligibility_results_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: eligibility_results_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.eligibility_results_id_seq OWNED BY public.eligibility_results.id;


--
-- Name: embedding_models; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.embedding_models (
    id bigint NOT NULL,
    provider text NOT NULL,
    key text NOT NULL,
    model_revision text NOT NULL,
    dimensions integer NOT NULL,
    distance_metric text NOT NULL,
    status text DEFAULT 'active'::text NOT NULL,
    configuration_hash bytea NOT NULL,
    activated_at timestamp(6) with time zone,
    retired_at timestamp(6) with time zone,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT embedding_models_configuration_hash_check CHECK ((octet_length(configuration_hash) = 32)),
    CONSTRAINT embedding_models_dimensions_check CHECK ((dimensions > 0)),
    CONSTRAINT embedding_models_distance_metric_check CHECK ((distance_metric = ANY (ARRAY['cosine'::text, 'l2'::text, 'inner_product'::text]))),
    CONSTRAINT embedding_models_retirement_after_activation_check CHECK (((activated_at IS NULL) OR (retired_at IS NULL) OR (retired_at >= activated_at))),
    CONSTRAINT embedding_models_retirement_state_check CHECK (((status = 'retired'::text) = (retired_at IS NOT NULL))),
    CONSTRAINT embedding_models_status_check CHECK ((status = ANY (ARRAY['active'::text, 'retired'::text])))
);


--
-- Name: embedding_models_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.embedding_models_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: embedding_models_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.embedding_models_id_seq OWNED BY public.embedding_models.id;


--
-- Name: embeddings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.embeddings (
    id bigint NOT NULL,
    search_document_id bigint NOT NULL,
    embedding_model_id bigint NOT NULL,
    value public.vector NOT NULL,
    dimensions integer NOT NULL,
    content_hash bytea NOT NULL,
    generated_at timestamp(6) with time zone NOT NULL,
    status text DEFAULT 'active'::text NOT NULL,
    error_code text,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT embeddings_content_hash_check CHECK ((octet_length(content_hash) = 32)),
    CONSTRAINT embeddings_dimension_check CHECK (((dimensions > 0) AND (public.vector_dims(value) = dimensions))),
    CONSTRAINT embeddings_error_state_check CHECK (((status = 'failed'::text) = (error_code IS NOT NULL))),
    CONSTRAINT embeddings_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'active'::text, 'superseded'::text, 'failed'::text])))
);


--
-- Name: embeddings_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.embeddings_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: embeddings_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.embeddings_id_seq OWNED BY public.embeddings.id;


--
-- Name: external_identities; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.external_identities (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    provider text NOT NULL,
    provider_subject_ciphertext text NOT NULL,
    provider_subject_digest bytea NOT NULL,
    digest_key_version smallint NOT NULL,
    email_verified_at timestamp(6) with time zone,
    claims_version smallint NOT NULL,
    last_authenticated_at timestamp(6) with time zone NOT NULL,
    encryption_context uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT external_identities_claims_version_check CHECK ((claims_version > 0)),
    CONSTRAINT external_identities_digest_key_version_check CHECK ((digest_key_version > 0)),
    CONSTRAINT external_identities_provider_check CHECK ((provider = 'google_oidc'::text)),
    CONSTRAINT external_identities_subject_digest_length_check CHECK ((octet_length(provider_subject_digest) = 32))
);


--
-- Name: external_identities_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.external_identities_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: external_identities_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.external_identities_id_seq OWNED BY public.external_identities.id;


--
-- Name: fact_definitions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.fact_definitions (
    id bigint NOT NULL,
    key text NOT NULL,
    label text NOT NULL,
    description text,
    data_type text NOT NULL,
    unit_dimension text,
    canonical_unit text,
    allowed_operators jsonb NOT NULL,
    allowed_operators_schema_version smallint NOT NULL,
    allowed_values_schema jsonb,
    allowed_values_schema_version smallint,
    hard_eligibility_supported boolean DEFAULT false NOT NULL,
    version integer NOT NULL,
    status text NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT fact_definitions_allowed_values_pair_check CHECK ((((data_type = 'enum'::text) AND (allowed_values_schema IS NOT NULL) AND (allowed_values_schema_version IS NOT NULL) AND (allowed_values_schema_version > 0)) OR ((data_type <> 'enum'::text) AND (allowed_values_schema IS NULL) AND (allowed_values_schema_version IS NULL)))),
    CONSTRAINT fact_definitions_measurement_check CHECK ((((data_type = 'measurement'::text) AND (NULLIF(btrim(unit_dimension), ''::text) IS NOT NULL) AND (NULLIF(btrim(canonical_unit), ''::text) IS NOT NULL)) OR ((data_type <> 'measurement'::text) AND (unit_dimension IS NULL) AND (canonical_unit IS NULL)))),
    CONSTRAINT fact_definitions_type_check CHECK ((data_type = ANY (ARRAY['boolean'::text, 'integer'::text, 'decimal'::text, 'text'::text, 'enum'::text, 'measurement'::text, 'json'::text]))),
    CONSTRAINT fact_definitions_versions_check CHECK (((allowed_operators_schema_version > 0) AND (version > 0)))
);


--
-- Name: fact_definitions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.fact_definitions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: fact_definitions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.fact_definitions_id_seq OWNED BY public.fact_definitions.id;


--
-- Name: inventory_observations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.inventory_observations (
    id bigint NOT NULL,
    supplier_id bigint NOT NULL,
    supplier_variant_id bigint NOT NULL,
    supplier_warehouse_id bigint NOT NULL,
    supplier_observation_id bigint NOT NULL,
    total_quantity bigint,
    cj_quantity bigint,
    factory_quantity bigint,
    verification_state text,
    observed_at timestamp(6) with time zone NOT NULL,
    valid_until timestamp(6) with time zone,
    created_at timestamp(6) with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT inventory_observations_quantities_check CHECK ((((total_quantity IS NULL) OR (total_quantity >= 0)) AND ((cj_quantity IS NULL) OR (cj_quantity >= 0)) AND ((factory_quantity IS NULL) OR (factory_quantity >= 0)))),
    CONSTRAINT inventory_observations_quantity_present_check CHECK ((num_nonnulls(total_quantity, cj_quantity, factory_quantity) >= 1)),
    CONSTRAINT inventory_observations_validity_check CHECK (((valid_until IS NULL) OR (valid_until >= observed_at)))
);


--
-- Name: inventory_observations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.inventory_observations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: inventory_observations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.inventory_observations_id_seq OWNED BY public.inventory_observations.id;


--
-- Name: price_observations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.price_observations (
    id bigint NOT NULL,
    supplier_id bigint NOT NULL,
    supplier_variant_id bigint NOT NULL,
    supplier_observation_id bigint NOT NULL,
    amount_minor bigint NOT NULL,
    currency character(3) NOT NULL,
    price_kind text NOT NULL,
    quantity_tier integer,
    observed_at timestamp(6) with time zone NOT NULL,
    valid_until timestamp(6) with time zone,
    created_at timestamp(6) with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT price_observations_amount_check CHECK ((amount_minor >= 0)),
    CONSTRAINT price_observations_currency_check CHECK ((currency ~ '^[A-Z]{3}$'::text)),
    CONSTRAINT price_observations_tier_check CHECK (((quantity_tier IS NULL) OR (quantity_tier > 0))),
    CONSTRAINT price_observations_validity_check CHECK (((valid_until IS NULL) OR (valid_until >= observed_at)))
);


--
-- Name: price_observations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.price_observations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: price_observations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.price_observations_id_seq OWNED BY public.price_observations.id;


--
-- Name: product_categories; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.product_categories (
    id bigint NOT NULL,
    product_id bigint NOT NULL,
    category_id bigint NOT NULL,
    provenance text NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL
);


--
-- Name: product_categories_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.product_categories_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: product_categories_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.product_categories_id_seq OWNED BY public.product_categories.id;


--
-- Name: product_facts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.product_facts (
    id bigint NOT NULL,
    product_id bigint,
    product_variant_id bigint,
    fact_definition_id bigint NOT NULL,
    boolean_value boolean,
    integer_value bigint,
    decimal_value numeric(20,6),
    text_value text,
    "json_value" jsonb,
    value_schema_version smallint,
    canonical_unit text,
    source_kind text NOT NULL,
    supplier_observation_id bigint,
    confidence numeric(8,6),
    inference_version text,
    observed_at timestamp(6) with time zone NOT NULL,
    valid_from timestamp(6) with time zone,
    valid_until timestamp(6) with time zone,
    status text NOT NULL,
    supersedes_product_fact_id bigint,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT product_facts_confidence_check CHECK (((confidence IS NULL) OR ((confidence <> ALL (ARRAY['NaN'::numeric, 'Infinity'::numeric, '-Infinity'::numeric])) AND ((confidence >= (0)::numeric) AND (confidence <= (1)::numeric))))),
    CONSTRAINT product_facts_decimal_finite_check CHECK (((decimal_value IS NULL) OR (decimal_value <> ALL (ARRAY['NaN'::numeric, 'Infinity'::numeric, '-Infinity'::numeric])))),
    CONSTRAINT product_facts_evidence_check CHECK (((source_kind = 'manual'::text) OR (supplier_observation_id IS NOT NULL))),
    CONSTRAINT product_facts_inference_check CHECK ((((source_kind = 'inferred'::text) AND (NULLIF(btrim(inference_version), ''::text) IS NOT NULL) AND (confidence IS NOT NULL)) OR ((source_kind <> 'inferred'::text) AND (inference_version IS NULL)))),
    CONSTRAINT product_facts_json_check CHECK ((("json_value" IS NULL) OR ((jsonb_typeof("json_value") = ANY (ARRAY['object'::text, 'array'::text])) AND (value_schema_version IS NOT NULL) AND (value_schema_version > 0)))),
    CONSTRAINT product_facts_not_self_superseding_check CHECK (((supersedes_product_fact_id IS NULL) OR (supersedes_product_fact_id <> id))),
    CONSTRAINT product_facts_source_check CHECK ((source_kind = ANY (ARRAY['supplier'::text, 'normalized'::text, 'inferred'::text, 'manual'::text]))),
    CONSTRAINT product_facts_status_check CHECK ((status = ANY (ARRAY['active'::text, 'superseded'::text, 'rejected'::text]))),
    CONSTRAINT product_facts_subject_check CHECK ((num_nonnulls(product_id, product_variant_id) = 1)),
    CONSTRAINT product_facts_text_bound_check CHECK (((text_value IS NULL) OR (octet_length(text_value) <= 1024))),
    CONSTRAINT product_facts_validity_check CHECK (((valid_until IS NULL) OR (valid_from IS NULL) OR (valid_until >= valid_from))),
    CONSTRAINT product_facts_value_check CHECK ((num_nonnulls(boolean_value, integer_value, decimal_value, text_value, "json_value") = 1)),
    CONSTRAINT product_facts_value_version_check CHECK ((("json_value" IS NOT NULL) OR (value_schema_version IS NULL)))
);


--
-- Name: product_facts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.product_facts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: product_facts_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.product_facts_id_seq OWNED BY public.product_facts.id;


--
-- Name: product_variants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.product_variants (
    id bigint NOT NULL,
    public_id uuid DEFAULT gen_random_uuid() NOT NULL,
    product_id bigint NOT NULL,
    canonical_sku text,
    title text NOT NULL,
    option_summary jsonb DEFAULT '{}'::jsonb NOT NULL,
    option_schema_version smallint NOT NULL,
    status text DEFAULT 'active'::text NOT NULL,
    weight_value numeric(14,4),
    weight_unit text,
    length_value numeric(14,4),
    width_value numeric(14,4),
    height_value numeric(14,4),
    dimension_unit text,
    lock_version integer DEFAULT 0 NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT product_variants_dimension_unit_check CHECK (((dimension_unit IS NULL) = ((length_value IS NULL) AND (width_value IS NULL) AND (height_value IS NULL)))),
    CONSTRAINT product_variants_lock_version_check CHECK ((lock_version >= 0)),
    CONSTRAINT product_variants_measurements_nonnegative_check CHECK ((((weight_value IS NULL) OR ((weight_value <> 'NaN'::numeric) AND (weight_value >= (0)::numeric))) AND ((length_value IS NULL) OR ((length_value <> 'NaN'::numeric) AND (length_value >= (0)::numeric))) AND ((width_value IS NULL) OR ((width_value <> 'NaN'::numeric) AND (width_value >= (0)::numeric))) AND ((height_value IS NULL) OR ((height_value <> 'NaN'::numeric) AND (height_value >= (0)::numeric))))),
    CONSTRAINT product_variants_option_object_check CHECK ((jsonb_typeof(option_summary) = 'object'::text)),
    CONSTRAINT product_variants_option_version_check CHECK ((option_schema_version > 0)),
    CONSTRAINT product_variants_status_check CHECK ((status = ANY (ARRAY['active'::text, 'unavailable'::text, 'retired'::text]))),
    CONSTRAINT product_variants_weight_unit_pair_check CHECK (((weight_value IS NULL) = (weight_unit IS NULL)))
);


--
-- Name: product_variants_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.product_variants_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: product_variants_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.product_variants_id_seq OWNED BY public.product_variants.id;


--
-- Name: products; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.products (
    id bigint NOT NULL,
    public_id uuid DEFAULT gen_random_uuid() NOT NULL,
    status text DEFAULT 'draft'::text NOT NULL,
    title text NOT NULL,
    description text DEFAULT ''::text NOT NULL,
    product_type text,
    brand text,
    primary_category_id bigint,
    published_at timestamp(6) with time zone,
    retired_at timestamp(6) with time zone,
    lock_version integer DEFAULT 0 NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT products_lock_version_check CHECK ((lock_version >= 0)),
    CONSTRAINT products_retired_after_published_check CHECK (((published_at IS NULL) OR (retired_at IS NULL) OR (retired_at >= published_at))),
    CONSTRAINT products_retired_state_check CHECK (((status = 'retired'::text) = (retired_at IS NOT NULL))),
    CONSTRAINT products_status_check CHECK ((status = ANY (ARRAY['draft'::text, 'active'::text, 'unavailable'::text, 'retired'::text])))
);


--
-- Name: products_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.products_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: products_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.products_id_seq OWNED BY public.products.id;


--
-- Name: recommendation_candidates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recommendation_candidates (
    id bigint NOT NULL,
    recommendation_run_id bigint NOT NULL,
    product_id bigint NOT NULL,
    product_variant_id bigint,
    retrieval_source text NOT NULL,
    retrieval_rank integer NOT NULL,
    lexical_score numeric(12,6),
    semantic_score numeric(12,6),
    soft_score numeric(12,6),
    final_eligibility text NOT NULL,
    final_rank integer,
    included boolean DEFAULT false NOT NULL,
    reason_code text NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT recommendation_candidates_eligibility_check CHECK ((final_eligibility = ANY (ARRAY['pass'::text, 'fail'::text, 'unknown'::text]))),
    CONSTRAINT recommendation_candidates_final_rank_check CHECK (((final_rank IS NULL) OR (final_rank > 0))),
    CONSTRAINT recommendation_candidates_retrieval_rank_check CHECK ((retrieval_rank > 0))
);


--
-- Name: recommendation_candidates_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.recommendation_candidates_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: recommendation_candidates_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.recommendation_candidates_id_seq OWNED BY public.recommendation_candidates.id;


--
-- Name: recommendation_evidence; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recommendation_evidence (
    id bigint NOT NULL,
    recommendation_candidate_id bigint NOT NULL,
    product_fact_id bigint,
    price_observation_id bigint,
    inventory_observation_id bigint,
    supplier_observation_id bigint,
    freshness_at timestamp(6) with time zone NOT NULL,
    display_excerpt text,
    created_at timestamp(6) with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT recommendation_evidence_subject_check CHECK ((num_nonnulls(product_fact_id, price_observation_id, inventory_observation_id, supplier_observation_id) = 1))
);


--
-- Name: recommendation_evidence_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.recommendation_evidence_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: recommendation_evidence_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.recommendation_evidence_id_seq OWNED BY public.recommendation_evidence.id;


--
-- Name: recommendation_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recommendation_runs (
    id bigint NOT NULL,
    public_id uuid DEFAULT gen_random_uuid() NOT NULL,
    shopping_session_id bigint NOT NULL,
    requirement_set_hash bytea NOT NULL,
    search_policy_version text NOT NULL,
    status text DEFAULT 'queued'::text NOT NULL,
    started_at timestamp(6) with time zone,
    completed_at timestamp(6) with time zone,
    query_limit integer NOT NULL,
    candidate_limit integer NOT NULL,
    result_summary jsonb DEFAULT '{}'::jsonb NOT NULL,
    result_schema_version smallint NOT NULL,
    no_result_reason text,
    history_influenced boolean DEFAULT false NOT NULL,
    latency_ms integer,
    cost_microunits bigint,
    lease_owner text,
    lease_token uuid,
    lease_expires_at timestamp(6) with time zone,
    purge_after timestamp(6) with time zone NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT recommendation_runs_candidate_limit_check CHECK ((candidate_limit > 0)),
    CONSTRAINT recommendation_runs_completion_check CHECK (((completed_at IS NULL) OR (started_at IS NULL) OR (completed_at >= started_at))),
    CONSTRAINT recommendation_runs_cost_check CHECK (((cost_microunits IS NULL) OR (cost_microunits >= 0))),
    CONSTRAINT recommendation_runs_hash_length_check CHECK ((octet_length(requirement_set_hash) = 32)),
    CONSTRAINT recommendation_runs_latency_check CHECK (((latency_ms IS NULL) OR (latency_ms >= 0))),
    CONSTRAINT recommendation_runs_lease_pair_check CHECK ((((lease_owner IS NULL) AND (lease_token IS NULL) AND (lease_expires_at IS NULL)) OR ((lease_owner IS NOT NULL) AND (lease_token IS NOT NULL) AND (lease_expires_at IS NOT NULL)))),
    CONSTRAINT recommendation_runs_query_limit_check CHECK ((query_limit > 0)),
    CONSTRAINT recommendation_runs_result_object_check CHECK ((jsonb_typeof(result_summary) = 'object'::text)),
    CONSTRAINT recommendation_runs_result_version_check CHECK ((result_schema_version > 0)),
    CONSTRAINT recommendation_runs_status_check CHECK ((status = ANY (ARRAY['queued'::text, 'running'::text, 'succeeded'::text, 'no_result'::text, 'failed'::text, 'cancelled'::text])))
);


--
-- Name: recommendation_runs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.recommendation_runs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: recommendation_runs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.recommendation_runs_id_seq OWNED BY public.recommendation_runs.id;


--
-- Name: requirements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.requirements (
    id bigint NOT NULL,
    public_id uuid DEFAULT gen_random_uuid() NOT NULL,
    shopping_session_id bigint NOT NULL,
    requirement_key text NOT NULL,
    operator text NOT NULL,
    kind text NOT NULL,
    value_json jsonb NOT NULL,
    value_schema_version smallint NOT NULL,
    source text NOT NULL,
    confidence numeric(8,6) NOT NULL,
    importance numeric(8,6) NOT NULL,
    needs_clarification boolean DEFAULT false NOT NULL,
    status text DEFAULT 'active'::text NOT NULL,
    originating_message_id bigint,
    originating_tool_call_id bigint,
    supersedes_requirement_id bigint,
    confirmed_at timestamp(6) with time zone,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT requirements_confidence_check CHECK (((confidence >= (0)::numeric) AND (confidence <= (1)::numeric))),
    CONSTRAINT requirements_importance_check CHECK (((importance >= (0)::numeric) AND (importance <= (1)::numeric))),
    CONSTRAINT requirements_kind_check CHECK ((kind = ANY (ARRAY['hard'::text, 'soft'::text]))),
    CONSTRAINT requirements_not_self_superseding_check CHECK (((supersedes_requirement_id IS NULL) OR (supersedes_requirement_id <> id))),
    CONSTRAINT requirements_source_check CHECK ((source = ANY (ARRAY['user_explicit'::text, 'user_inferred'::text, 'system_derived'::text, 'history_soft'::text]))),
    CONSTRAINT requirements_status_check CHECK ((status = ANY (ARRAY['active'::text, 'rejected'::text, 'superseded'::text]))),
    CONSTRAINT requirements_value_json_object_check CHECK ((jsonb_typeof(value_json) = 'object'::text)),
    CONSTRAINT requirements_value_schema_version_check CHECK ((value_schema_version > 0))
);


--
-- Name: requirements_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.requirements_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: requirements_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.requirements_id_seq OWNED BY public.requirements.id;


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


--
-- Name: search_documents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.search_documents (
    id bigint NOT NULL,
    product_id bigint,
    product_variant_id bigint,
    document_kind text NOT NULL,
    locale text DEFAULT 'en'::text NOT NULL,
    normalized_text text NOT NULL,
    content_hash bytea NOT NULL,
    source_version text NOT NULL,
    status text NOT NULL,
    generated_at timestamp(6) with time zone NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    search_vector tsvector GENERATED ALWAYS AS (to_tsvector('english'::regconfig, normalized_text)) STORED,
    CONSTRAINT search_documents_content_hash_check CHECK ((octet_length(content_hash) = 32)),
    CONSTRAINT search_documents_status_check CHECK ((status = ANY (ARRAY['active'::text, 'superseded'::text]))),
    CONSTRAINT search_documents_subject_check CHECK ((num_nonnulls(product_id, product_variant_id) = 1))
);


--
-- Name: search_documents_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.search_documents_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: search_documents_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.search_documents_id_seq OWNED BY public.search_documents.id;


--
-- Name: shopping_messages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.shopping_messages (
    id bigint NOT NULL,
    shopping_session_id bigint NOT NULL,
    ai_access_grant_id bigint,
    role text NOT NULL,
    source text NOT NULL,
    text_ciphertext text,
    redacted_text text,
    provider_message_ref_digest bytea,
    digest_key_version smallint,
    sequence bigint NOT NULL,
    occurred_at timestamp(6) with time zone NOT NULL,
    purge_after timestamp(6) with time zone NOT NULL,
    safety_status text DEFAULT 'unchecked'::text NOT NULL,
    redaction_status text DEFAULT 'pending'::text NOT NULL,
    created_at timestamp(6) with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT shopping_messages_digest_key_version_check CHECK (((digest_key_version IS NULL) OR (digest_key_version > 0))),
    CONSTRAINT shopping_messages_digest_length_check CHECK (((provider_message_ref_digest IS NULL) OR (octet_length(provider_message_ref_digest) = 32))),
    CONSTRAINT shopping_messages_digest_pair_check CHECK (((provider_message_ref_digest IS NULL) = (digest_key_version IS NULL))),
    CONSTRAINT shopping_messages_purge_deadline_check CHECK ((purge_after >= occurred_at)),
    CONSTRAINT shopping_messages_role_check CHECK ((role = ANY (ARRAY['user'::text, 'agent'::text, 'system_event'::text]))),
    CONSTRAINT shopping_messages_sequence_check CHECK ((sequence > 0))
);


--
-- Name: shopping_messages_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.shopping_messages_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: shopping_messages_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.shopping_messages_id_seq OWNED BY public.shopping_messages.id;


--
-- Name: shopping_sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.shopping_sessions (
    id bigint NOT NULL,
    public_id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id bigint,
    status text DEFAULT 'active'::text NOT NULL,
    started_at timestamp(6) with time zone NOT NULL,
    last_activity_at timestamp(6) with time zone NOT NULL,
    expires_at timestamp(6) with time zone NOT NULL,
    coarse_region_code text,
    abuse_level smallint DEFAULT 0 NOT NULL,
    lock_version integer DEFAULT 0 NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT shopping_sessions_abuse_level_check CHECK (((abuse_level >= 0) AND (abuse_level <= 4))),
    CONSTRAINT shopping_sessions_expiry_check CHECK ((expires_at > started_at)),
    CONSTRAINT shopping_sessions_lock_version_check CHECK ((lock_version >= 0)),
    CONSTRAINT shopping_sessions_status_check CHECK ((status = ANY (ARRAY['active'::text, 'expired'::text, 'blocked'::text, 'closed'::text])))
);


--
-- Name: shopping_sessions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.shopping_sessions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: shopping_sessions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.shopping_sessions_id_seq OWNED BY public.shopping_sessions.id;


--
-- Name: supplier_observations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.supplier_observations (
    id bigint NOT NULL,
    supplier_id bigint NOT NULL,
    resource_kind text NOT NULL,
    external_resource_id text NOT NULL,
    provider_request_id text,
    endpoint_key text NOT NULL,
    adapter_version text NOT NULL,
    payload_schema_version smallint NOT NULL,
    payload_ciphertext text,
    payload_json jsonb,
    payload_sha256 bytea NOT NULL,
    encryption_context uuid DEFAULT gen_random_uuid() NOT NULL,
    observed_at timestamp(6) with time zone NOT NULL,
    received_at timestamp(6) with time zone NOT NULL,
    normalization_status text DEFAULT 'pending'::text NOT NULL,
    normalization_error_code text,
    purge_after timestamp(6) with time zone NOT NULL,
    purged_at timestamp(6) with time zone,
    created_at timestamp(6) with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT supplier_observations_hash_check CHECK ((octet_length(payload_sha256) = 32)),
    CONSTRAINT supplier_observations_normalization_error_check CHECK (((normalization_status = 'failed'::text) = (normalization_error_code IS NOT NULL))),
    CONSTRAINT supplier_observations_normalization_status_check CHECK ((normalization_status = ANY (ARRAY['pending'::text, 'normalized'::text, 'failed'::text]))),
    CONSTRAINT supplier_observations_payload_lifecycle_check CHECK ((((purged_at IS NULL) AND (num_nonnulls(payload_ciphertext, payload_json) = 1)) OR ((purged_at IS NOT NULL) AND (payload_ciphertext IS NULL) AND (payload_json IS NULL) AND (purged_at >= purge_after)))),
    CONSTRAINT supplier_observations_payload_object_check CHECK (((payload_json IS NULL) OR (jsonb_typeof(payload_json) = 'object'::text))),
    CONSTRAINT supplier_observations_payload_version_check CHECK ((payload_schema_version > 0)),
    CONSTRAINT supplier_observations_purge_deadline_check CHECK ((purge_after >= received_at))
);


--
-- Name: supplier_observations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.supplier_observations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: supplier_observations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.supplier_observations_id_seq OWNED BY public.supplier_observations.id;


--
-- Name: supplier_products; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.supplier_products (
    id bigint NOT NULL,
    supplier_id bigint NOT NULL,
    product_id bigint NOT NULL,
    external_product_id text NOT NULL,
    external_sku text,
    external_category_id text,
    status text NOT NULL,
    first_seen_at timestamp(6) with time zone NOT NULL,
    last_seen_at timestamp(6) with time zone NOT NULL,
    last_synced_at timestamp(6) with time zone,
    adapter_version text NOT NULL,
    latest_observation_id bigint,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT supplier_products_seen_time_check CHECK ((last_seen_at >= first_seen_at)),
    CONSTRAINT supplier_products_sync_time_check CHECK (((last_synced_at IS NULL) OR (last_synced_at >= last_seen_at)))
);


--
-- Name: supplier_products_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.supplier_products_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: supplier_products_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.supplier_products_id_seq OWNED BY public.supplier_products.id;


--
-- Name: supplier_subscriptions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.supplier_subscriptions (
    id bigint NOT NULL,
    supplier_id bigint NOT NULL,
    supplier_product_id bigint NOT NULL,
    topic text NOT NULL,
    external_ref_ciphertext text,
    external_ref_digest bytea,
    digest_key_version smallint,
    encryption_context uuid DEFAULT gen_random_uuid() NOT NULL,
    status text DEFAULT 'requested'::text NOT NULL,
    requested_at timestamp(6) with time zone NOT NULL,
    confirmed_at timestamp(6) with time zone,
    last_verified_at timestamp(6) with time zone,
    closed_at timestamp(6) with time zone,
    close_reason text,
    retry_count integer DEFAULT 0 NOT NULL,
    next_retry_at timestamp(6) with time zone,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT supplier_subscriptions_digest_check CHECK (((external_ref_digest IS NULL) OR (octet_length(external_ref_digest) = 32))),
    CONSTRAINT supplier_subscriptions_digest_version_check CHECK (((digest_key_version IS NULL) OR (digest_key_version > 0))),
    CONSTRAINT supplier_subscriptions_external_ref_pair_check CHECK ((num_nonnulls(external_ref_ciphertext, external_ref_digest, digest_key_version) = ANY (ARRAY[0, 3]))),
    CONSTRAINT supplier_subscriptions_retry_count_check CHECK ((retry_count >= 0))
);


--
-- Name: supplier_subscriptions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.supplier_subscriptions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: supplier_subscriptions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.supplier_subscriptions_id_seq OWNED BY public.supplier_subscriptions.id;


--
-- Name: supplier_variants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.supplier_variants (
    id bigint NOT NULL,
    supplier_id bigint NOT NULL,
    product_variant_id bigint NOT NULL,
    supplier_product_id bigint NOT NULL,
    external_variant_id text NOT NULL,
    external_variant_sku text,
    barcode text,
    weight_value numeric(14,4),
    weight_unit text,
    length_value numeric(14,4),
    width_value numeric(14,4),
    height_value numeric(14,4),
    dimension_unit text,
    status text NOT NULL,
    first_seen_at timestamp(6) with time zone NOT NULL,
    last_seen_at timestamp(6) with time zone NOT NULL,
    last_synced_at timestamp(6) with time zone,
    latest_observation_id bigint,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT supplier_variants_dimension_unit_check CHECK (((dimension_unit IS NULL) = ((length_value IS NULL) AND (width_value IS NULL) AND (height_value IS NULL)))),
    CONSTRAINT supplier_variants_measurements_nonnegative_check CHECK ((((weight_value IS NULL) OR ((weight_value <> 'NaN'::numeric) AND (weight_value >= (0)::numeric))) AND ((length_value IS NULL) OR ((length_value <> 'NaN'::numeric) AND (length_value >= (0)::numeric))) AND ((width_value IS NULL) OR ((width_value <> 'NaN'::numeric) AND (width_value >= (0)::numeric))) AND ((height_value IS NULL) OR ((height_value <> 'NaN'::numeric) AND (height_value >= (0)::numeric))))),
    CONSTRAINT supplier_variants_seen_time_check CHECK ((last_seen_at >= first_seen_at)),
    CONSTRAINT supplier_variants_sync_time_check CHECK (((last_synced_at IS NULL) OR (last_synced_at >= last_seen_at))),
    CONSTRAINT supplier_variants_weight_unit_pair_check CHECK (((weight_value IS NULL) = (weight_unit IS NULL)))
);


--
-- Name: supplier_variants_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.supplier_variants_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: supplier_variants_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.supplier_variants_id_seq OWNED BY public.supplier_variants.id;


--
-- Name: supplier_warehouses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.supplier_warehouses (
    id bigint NOT NULL,
    supplier_id bigint NOT NULL,
    external_warehouse_id text NOT NULL,
    country_code character(2),
    region_code text,
    name text,
    verification_state text,
    status text NOT NULL,
    first_seen_at timestamp(6) with time zone NOT NULL,
    last_seen_at timestamp(6) with time zone NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT supplier_warehouses_country_code_check CHECK (((country_code IS NULL) OR (country_code ~ '^[A-Z]{2}$'::text))),
    CONSTRAINT supplier_warehouses_seen_time_check CHECK ((last_seen_at >= first_seen_at))
);


--
-- Name: supplier_warehouses_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.supplier_warehouses_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: supplier_warehouses_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.supplier_warehouses_id_seq OWNED BY public.supplier_warehouses.id;


--
-- Name: suppliers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.suppliers (
    id bigint NOT NULL,
    key text NOT NULL,
    display_name text NOT NULL,
    adapter_version text NOT NULL,
    api_version text NOT NULL,
    status text DEFAULT 'active'::text NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT suppliers_status_check CHECK ((status = ANY (ARRAY['active'::text, 'disabled'::text])))
);


--
-- Name: suppliers_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.suppliers_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: suppliers_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.suppliers_id_seq OWNED BY public.suppliers.id;


--
-- Name: sync_checkpoints; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sync_checkpoints (
    id bigint NOT NULL,
    sync_run_id bigint NOT NULL,
    checkpoint_key text NOT NULL,
    cursor text,
    page_number integer,
    state_json jsonb DEFAULT '{}'::jsonb NOT NULL,
    state_schema_version smallint NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT sync_checkpoints_page_check CHECK (((page_number IS NULL) OR (page_number > 0))),
    CONSTRAINT sync_checkpoints_state_check CHECK (((jsonb_typeof(state_json) = 'object'::text) AND (state_schema_version > 0)))
);


--
-- Name: sync_checkpoints_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.sync_checkpoints_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sync_checkpoints_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.sync_checkpoints_id_seq OWNED BY public.sync_checkpoints.id;


--
-- Name: sync_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sync_runs (
    id bigint NOT NULL,
    public_id uuid DEFAULT gen_random_uuid() NOT NULL,
    supplier_id bigint NOT NULL,
    mode text NOT NULL,
    resource_kind text NOT NULL,
    scope_key text NOT NULL,
    scope_json jsonb DEFAULT '{}'::jsonb NOT NULL,
    scope_schema_version smallint NOT NULL,
    adapter_version text NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    points_consumed bigint DEFAULT 0 NOT NULL,
    seen_count bigint DEFAULT 0 NOT NULL,
    created_count bigint DEFAULT 0 NOT NULL,
    updated_count bigint DEFAULT 0 NOT NULL,
    error_count bigint DEFAULT 0 NOT NULL,
    started_at timestamp(6) with time zone,
    completed_at timestamp(6) with time zone,
    error_code text,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT sync_runs_completion_check CHECK (((completed_at IS NULL) OR ((started_at IS NOT NULL) AND (completed_at >= started_at)))),
    CONSTRAINT sync_runs_counts_check CHECK (((points_consumed >= 0) AND (seen_count >= 0) AND (created_count >= 0) AND (updated_count >= 0) AND (error_count >= 0))),
    CONSTRAINT sync_runs_mode_check CHECK ((mode = ANY (ARRAY['fixture'::text, 'verify'::text, 'record'::text, 'live'::text]))),
    CONSTRAINT sync_runs_scope_check CHECK (((jsonb_typeof(scope_json) = 'object'::text) AND (scope_schema_version > 0))),
    CONSTRAINT sync_runs_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'running'::text, 'succeeded'::text, 'failed'::text, 'cancelled'::text])))
);


--
-- Name: sync_runs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.sync_runs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sync_runs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.sync_runs_id_seq OWNED BY public.sync_runs.id;


--
-- Name: turnstile_verifications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.turnstile_verifications (
    id bigint NOT NULL,
    shopping_session_id bigint NOT NULL,
    token_digest bytea NOT NULL,
    expected_action text NOT NULL,
    validated_hostname text NOT NULL,
    success boolean NOT NULL,
    failure_code text,
    challenge_timestamp timestamp(6) with time zone NOT NULL,
    validated_at timestamp(6) with time zone NOT NULL,
    expires_at timestamp(6) with time zone NOT NULL,
    source_key_digest bytea,
    source_key_version smallint,
    purge_after timestamp(6) with time zone NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT turnstile_verifications_challenge_time_check CHECK ((challenge_timestamp <= validated_at)),
    CONSTRAINT turnstile_verifications_expiry_check CHECK (((expires_at > validated_at) AND (expires_at <= (validated_at + '00:05:00'::interval)))),
    CONSTRAINT turnstile_verifications_source_key_length_check CHECK (((source_key_digest IS NULL) OR (octet_length(source_key_digest) = 32))),
    CONSTRAINT turnstile_verifications_source_key_pair_check CHECK (((source_key_digest IS NULL) = (source_key_version IS NULL))),
    CONSTRAINT turnstile_verifications_source_key_version_check CHECK (((source_key_version IS NULL) OR (source_key_version > 0))),
    CONSTRAINT turnstile_verifications_token_digest_length_check CHECK ((octet_length(token_digest) = 32))
);


--
-- Name: turnstile_verifications_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.turnstile_verifications_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: turnstile_verifications_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.turnstile_verifications_id_seq OWNED BY public.turnstile_verifications.id;


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id bigint NOT NULL,
    public_id uuid DEFAULT gen_random_uuid() NOT NULL,
    status text DEFAULT 'active'::text NOT NULL,
    email_ciphertext text,
    email_lookup_digest bytea,
    email_digest_key_version smallint,
    locale text,
    region_code text,
    last_authenticated_at timestamp(6) with time zone,
    lock_version integer DEFAULT 0 NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT users_email_digest_key_version_check CHECK (((email_digest_key_version IS NULL) OR (email_digest_key_version > 0))),
    CONSTRAINT users_email_digest_length_check CHECK (((email_lookup_digest IS NULL) OR (octet_length(email_lookup_digest) = 32))),
    CONSTRAINT users_email_digest_pair_check CHECK (((email_lookup_digest IS NULL) = (email_digest_key_version IS NULL))),
    CONSTRAINT users_lock_version_check CHECK ((lock_version >= 0)),
    CONSTRAINT users_status_check CHECK ((status = ANY (ARRAY['active'::text, 'disabled'::text, 'deletion_pending'::text])))
);


--
-- Name: users_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.users_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: users_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.users_id_seq OWNED BY public.users.id;


--
-- Name: agent_provider_sessions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_provider_sessions ALTER COLUMN id SET DEFAULT nextval('public.agent_provider_sessions_id_seq'::regclass);


--
-- Name: agent_runs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_runs ALTER COLUMN id SET DEFAULT nextval('public.agent_runs_id_seq'::regclass);


--
-- Name: agent_tool_calls id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_tool_calls ALTER COLUMN id SET DEFAULT nextval('public.agent_tool_calls_id_seq'::regclass);


--
-- Name: ai_access_grants id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_access_grants ALTER COLUMN id SET DEFAULT nextval('public.ai_access_grants_id_seq'::regclass);


--
-- Name: catalog_media id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_media ALTER COLUMN id SET DEFAULT nextval('public.catalog_media_id_seq'::regclass);


--
-- Name: categories id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.categories ALTER COLUMN id SET DEFAULT nextval('public.categories_id_seq'::regclass);


--
-- Name: clarification_decisions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.clarification_decisions ALTER COLUMN id SET DEFAULT nextval('public.clarification_decisions_id_seq'::regclass);


--
-- Name: consent_records id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.consent_records ALTER COLUMN id SET DEFAULT nextval('public.consent_records_id_seq'::regclass);


--
-- Name: eligibility_results id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.eligibility_results ALTER COLUMN id SET DEFAULT nextval('public.eligibility_results_id_seq'::regclass);


--
-- Name: embedding_models id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.embedding_models ALTER COLUMN id SET DEFAULT nextval('public.embedding_models_id_seq'::regclass);


--
-- Name: embeddings id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.embeddings ALTER COLUMN id SET DEFAULT nextval('public.embeddings_id_seq'::regclass);


--
-- Name: external_identities id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.external_identities ALTER COLUMN id SET DEFAULT nextval('public.external_identities_id_seq'::regclass);


--
-- Name: fact_definitions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fact_definitions ALTER COLUMN id SET DEFAULT nextval('public.fact_definitions_id_seq'::regclass);


--
-- Name: inventory_observations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_observations ALTER COLUMN id SET DEFAULT nextval('public.inventory_observations_id_seq'::regclass);


--
-- Name: price_observations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.price_observations ALTER COLUMN id SET DEFAULT nextval('public.price_observations_id_seq'::regclass);


--
-- Name: product_categories id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_categories ALTER COLUMN id SET DEFAULT nextval('public.product_categories_id_seq'::regclass);


--
-- Name: product_facts id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_facts ALTER COLUMN id SET DEFAULT nextval('public.product_facts_id_seq'::regclass);


--
-- Name: product_variants id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_variants ALTER COLUMN id SET DEFAULT nextval('public.product_variants_id_seq'::regclass);


--
-- Name: products id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.products ALTER COLUMN id SET DEFAULT nextval('public.products_id_seq'::regclass);


--
-- Name: recommendation_candidates id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recommendation_candidates ALTER COLUMN id SET DEFAULT nextval('public.recommendation_candidates_id_seq'::regclass);


--
-- Name: recommendation_evidence id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recommendation_evidence ALTER COLUMN id SET DEFAULT nextval('public.recommendation_evidence_id_seq'::regclass);


--
-- Name: recommendation_runs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recommendation_runs ALTER COLUMN id SET DEFAULT nextval('public.recommendation_runs_id_seq'::regclass);


--
-- Name: requirements id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.requirements ALTER COLUMN id SET DEFAULT nextval('public.requirements_id_seq'::regclass);


--
-- Name: search_documents id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.search_documents ALTER COLUMN id SET DEFAULT nextval('public.search_documents_id_seq'::regclass);


--
-- Name: shopping_messages id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shopping_messages ALTER COLUMN id SET DEFAULT nextval('public.shopping_messages_id_seq'::regclass);


--
-- Name: shopping_sessions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shopping_sessions ALTER COLUMN id SET DEFAULT nextval('public.shopping_sessions_id_seq'::regclass);


--
-- Name: supplier_observations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supplier_observations ALTER COLUMN id SET DEFAULT nextval('public.supplier_observations_id_seq'::regclass);


--
-- Name: supplier_products id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supplier_products ALTER COLUMN id SET DEFAULT nextval('public.supplier_products_id_seq'::regclass);


--
-- Name: supplier_subscriptions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supplier_subscriptions ALTER COLUMN id SET DEFAULT nextval('public.supplier_subscriptions_id_seq'::regclass);


--
-- Name: supplier_variants id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supplier_variants ALTER COLUMN id SET DEFAULT nextval('public.supplier_variants_id_seq'::regclass);


--
-- Name: supplier_warehouses id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supplier_warehouses ALTER COLUMN id SET DEFAULT nextval('public.supplier_warehouses_id_seq'::regclass);


--
-- Name: suppliers id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.suppliers ALTER COLUMN id SET DEFAULT nextval('public.suppliers_id_seq'::regclass);


--
-- Name: sync_checkpoints id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sync_checkpoints ALTER COLUMN id SET DEFAULT nextval('public.sync_checkpoints_id_seq'::regclass);


--
-- Name: sync_runs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sync_runs ALTER COLUMN id SET DEFAULT nextval('public.sync_runs_id_seq'::regclass);


--
-- Name: turnstile_verifications id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.turnstile_verifications ALTER COLUMN id SET DEFAULT nextval('public.turnstile_verifications_id_seq'::regclass);


--
-- Name: users id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users ALTER COLUMN id SET DEFAULT nextval('public.users_id_seq'::regclass);


--
-- Name: agent_provider_sessions agent_provider_sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_provider_sessions
    ADD CONSTRAINT agent_provider_sessions_pkey PRIMARY KEY (id);


--
-- Name: agent_runs agent_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_runs
    ADD CONSTRAINT agent_runs_pkey PRIMARY KEY (id);


--
-- Name: agent_tool_calls agent_tool_calls_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_tool_calls
    ADD CONSTRAINT agent_tool_calls_pkey PRIMARY KEY (id);


--
-- Name: ai_access_grants ai_access_grants_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_access_grants
    ADD CONSTRAINT ai_access_grants_pkey PRIMARY KEY (id);


--
-- Name: ar_internal_metadata ar_internal_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ar_internal_metadata
    ADD CONSTRAINT ar_internal_metadata_pkey PRIMARY KEY (key);


--
-- Name: catalog_media catalog_media_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_media
    ADD CONSTRAINT catalog_media_pkey PRIMARY KEY (id);


--
-- Name: categories categories_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.categories
    ADD CONSTRAINT categories_pkey PRIMARY KEY (id);


--
-- Name: clarification_decisions clarification_decisions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.clarification_decisions
    ADD CONSTRAINT clarification_decisions_pkey PRIMARY KEY (id);


--
-- Name: consent_records consent_records_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.consent_records
    ADD CONSTRAINT consent_records_pkey PRIMARY KEY (id);


--
-- Name: eligibility_results eligibility_results_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.eligibility_results
    ADD CONSTRAINT eligibility_results_pkey PRIMARY KEY (id);


--
-- Name: embedding_models embedding_models_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.embedding_models
    ADD CONSTRAINT embedding_models_pkey PRIMARY KEY (id);


--
-- Name: embeddings embeddings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.embeddings
    ADD CONSTRAINT embeddings_pkey PRIMARY KEY (id);


--
-- Name: external_identities external_identities_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.external_identities
    ADD CONSTRAINT external_identities_pkey PRIMARY KEY (id);


--
-- Name: fact_definitions fact_definitions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fact_definitions
    ADD CONSTRAINT fact_definitions_pkey PRIMARY KEY (id);


--
-- Name: inventory_observations inventory_observations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_observations
    ADD CONSTRAINT inventory_observations_pkey PRIMARY KEY (id);


--
-- Name: price_observations price_observations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.price_observations
    ADD CONSTRAINT price_observations_pkey PRIMARY KEY (id);


--
-- Name: product_categories product_categories_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_categories
    ADD CONSTRAINT product_categories_pkey PRIMARY KEY (id);


--
-- Name: product_facts product_facts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_facts
    ADD CONSTRAINT product_facts_pkey PRIMARY KEY (id);


--
-- Name: product_variants product_variants_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_variants
    ADD CONSTRAINT product_variants_pkey PRIMARY KEY (id);


--
-- Name: products products_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_pkey PRIMARY KEY (id);


--
-- Name: recommendation_candidates recommendation_candidates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recommendation_candidates
    ADD CONSTRAINT recommendation_candidates_pkey PRIMARY KEY (id);


--
-- Name: recommendation_evidence recommendation_evidence_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recommendation_evidence
    ADD CONSTRAINT recommendation_evidence_pkey PRIMARY KEY (id);


--
-- Name: recommendation_runs recommendation_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recommendation_runs
    ADD CONSTRAINT recommendation_runs_pkey PRIMARY KEY (id);


--
-- Name: requirements requirements_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.requirements
    ADD CONSTRAINT requirements_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: search_documents search_documents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.search_documents
    ADD CONSTRAINT search_documents_pkey PRIMARY KEY (id);


--
-- Name: shopping_messages shopping_messages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shopping_messages
    ADD CONSTRAINT shopping_messages_pkey PRIMARY KEY (id);


--
-- Name: shopping_sessions shopping_sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shopping_sessions
    ADD CONSTRAINT shopping_sessions_pkey PRIMARY KEY (id);


--
-- Name: supplier_observations supplier_observations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supplier_observations
    ADD CONSTRAINT supplier_observations_pkey PRIMARY KEY (id);


--
-- Name: supplier_products supplier_products_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supplier_products
    ADD CONSTRAINT supplier_products_pkey PRIMARY KEY (id);


--
-- Name: supplier_subscriptions supplier_subscriptions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supplier_subscriptions
    ADD CONSTRAINT supplier_subscriptions_pkey PRIMARY KEY (id);


--
-- Name: supplier_variants supplier_variants_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supplier_variants
    ADD CONSTRAINT supplier_variants_pkey PRIMARY KEY (id);


--
-- Name: supplier_warehouses supplier_warehouses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supplier_warehouses
    ADD CONSTRAINT supplier_warehouses_pkey PRIMARY KEY (id);


--
-- Name: suppliers suppliers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.suppliers
    ADD CONSTRAINT suppliers_pkey PRIMARY KEY (id);


--
-- Name: sync_checkpoints sync_checkpoints_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sync_checkpoints
    ADD CONSTRAINT sync_checkpoints_pkey PRIMARY KEY (id);


--
-- Name: sync_runs sync_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sync_runs
    ADD CONSTRAINT sync_runs_pkey PRIMARY KEY (id);


--
-- Name: turnstile_verifications turnstile_verifications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.turnstile_verifications
    ADD CONSTRAINT turnstile_verifications_pkey PRIMARY KEY (id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: idx_on_ai_access_grant_id_shopping_session_id_9e8d55f505; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_ai_access_grant_id_shopping_session_id_9e8d55f505 ON public.agent_provider_sessions USING btree (ai_access_grant_id, shopping_session_id);


--
-- Name: idx_on_supplier_id_external_warehouse_id_735098a127; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_supplier_id_external_warehouse_id_735098a127 ON public.supplier_warehouses USING btree (supplier_id, external_warehouse_id);


--
-- Name: idx_on_supplier_observation_id_supplier_id_3a12b0d8ae; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_supplier_observation_id_supplier_id_3a12b0d8ae ON public.inventory_observations USING btree (supplier_observation_id, supplier_id);


--
-- Name: idx_on_supplier_observation_id_supplier_id_8c925d892e; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_supplier_observation_id_supplier_id_8c925d892e ON public.price_observations USING btree (supplier_observation_id, supplier_id);


--
-- Name: idx_on_supplier_product_id_supplier_id_ed992adacc; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_supplier_product_id_supplier_id_ed992adacc ON public.supplier_subscriptions USING btree (supplier_product_id, supplier_id);


--
-- Name: idx_on_supplier_variant_id_supplier_id_32402e41dd; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_supplier_variant_id_supplier_id_32402e41dd ON public.inventory_observations USING btree (supplier_variant_id, supplier_id);


--
-- Name: idx_on_supplier_variant_id_supplier_id_415dc3ccfc; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_supplier_variant_id_supplier_id_415dc3ccfc ON public.price_observations USING btree (supplier_variant_id, supplier_id);


--
-- Name: idx_on_supplier_warehouse_id_supplier_id_03cdf1d29b; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_supplier_warehouse_id_supplier_id_03cdf1d29b ON public.inventory_observations USING btree (supplier_warehouse_id, supplier_id);


--
-- Name: index_agent_provider_sessions_on_active_session; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_agent_provider_sessions_on_active_session ON public.agent_provider_sessions USING btree (shopping_session_id) WHERE (status = ANY (ARRAY['starting'::text, 'active'::text]));


--
-- Name: index_agent_provider_sessions_on_encryption_context; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_agent_provider_sessions_on_encryption_context ON public.agent_provider_sessions USING btree (encryption_context);


--
-- Name: index_agent_provider_sessions_on_id_and_session; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_agent_provider_sessions_on_id_and_session ON public.agent_provider_sessions USING btree (id, shopping_session_id);


--
-- Name: index_agent_provider_sessions_on_provider_ref; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_agent_provider_sessions_on_provider_ref ON public.agent_provider_sessions USING btree (provider, digest_key_version, provider_session_ref_digest) WHERE (provider_session_ref_digest IS NOT NULL);


--
-- Name: index_agent_runs_on_active_session; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_agent_runs_on_active_session ON public.agent_runs USING btree (shopping_session_id) WHERE (status = ANY (ARRAY['queued'::text, 'running'::text]));


--
-- Name: index_agent_runs_on_correlation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_agent_runs_on_correlation_id ON public.agent_runs USING btree (correlation_id);


--
-- Name: index_agent_runs_on_grant_and_session; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_agent_runs_on_grant_and_session ON public.agent_runs USING btree (ai_access_grant_id, shopping_session_id);


--
-- Name: index_agent_runs_on_provider_session_and_session; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_agent_runs_on_provider_session_and_session ON public.agent_runs USING btree (agent_provider_session_id, shopping_session_id);


--
-- Name: index_agent_runs_on_public_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_agent_runs_on_public_id ON public.agent_runs USING btree (public_id);


--
-- Name: index_agent_runs_on_purge_after; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_agent_runs_on_purge_after ON public.agent_runs USING btree (purge_after);


--
-- Name: index_agent_tool_calls_on_purge_after; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_agent_tool_calls_on_purge_after ON public.agent_tool_calls USING btree (purge_after);


--
-- Name: index_agent_tool_calls_on_run_idempotency; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_agent_tool_calls_on_run_idempotency ON public.agent_tool_calls USING btree (agent_run_id, idempotency_key) WHERE (idempotency_key IS NOT NULL);


--
-- Name: index_agent_tool_calls_on_run_sequence; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_agent_tool_calls_on_run_sequence ON public.agent_tool_calls USING btree (agent_run_id, sequence);


--
-- Name: index_ai_access_grants_on_active_session; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_ai_access_grants_on_active_session ON public.ai_access_grants USING btree (shopping_session_id) WHERE (status = 'active'::text);


--
-- Name: index_ai_access_grants_on_disclosure_consent_record_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ai_access_grants_on_disclosure_consent_record_id ON public.ai_access_grants USING btree (disclosure_consent_record_id);


--
-- Name: index_ai_access_grants_on_grant_token_digest; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_ai_access_grants_on_grant_token_digest ON public.ai_access_grants USING btree (grant_token_digest);


--
-- Name: index_ai_access_grants_on_id_and_shopping_session_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_ai_access_grants_on_id_and_shopping_session_id ON public.ai_access_grants USING btree (id, shopping_session_id);


--
-- Name: index_ai_access_grants_on_public_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_ai_access_grants_on_public_id ON public.ai_access_grants USING btree (public_id);


--
-- Name: index_ai_access_grants_on_turnstile_verification_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_ai_access_grants_on_turnstile_verification_id ON public.ai_access_grants USING btree (turnstile_verification_id) WHERE (turnstile_verification_id IS NOT NULL);


--
-- Name: index_catalog_media_on_encryption_context; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_catalog_media_on_encryption_context ON public.catalog_media USING btree (encryption_context);


--
-- Name: index_catalog_media_on_supplier_observation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_catalog_media_on_supplier_observation_id ON public.catalog_media USING btree (supplier_observation_id);


--
-- Name: index_catalog_media_product_position; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_catalog_media_product_position ON public.catalog_media USING btree (product_id, "position", id) WHERE (product_id IS NOT NULL);


--
-- Name: index_catalog_media_variant_position; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_catalog_media_variant_position ON public.catalog_media USING btree (product_variant_id, "position", id) WHERE (product_variant_id IS NOT NULL);


--
-- Name: index_categories_on_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_categories_on_key ON public.categories USING btree (key);


--
-- Name: index_categories_on_parent_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_categories_on_parent_id ON public.categories USING btree (parent_id);


--
-- Name: index_categories_on_public_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_categories_on_public_id ON public.categories USING btree (public_id);


--
-- Name: index_clarification_decisions_on_recommendation_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_clarification_decisions_on_recommendation_run_id ON public.clarification_decisions USING btree (recommendation_run_id);


--
-- Name: index_clarification_decisions_on_requirement_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_clarification_decisions_on_requirement_id ON public.clarification_decisions USING btree (requirement_id);


--
-- Name: index_clarification_decisions_on_selected_message_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_clarification_decisions_on_selected_message_id ON public.clarification_decisions USING btree (selected_message_id);


--
-- Name: index_clarification_decisions_on_shopping_session_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_clarification_decisions_on_shopping_session_id ON public.clarification_decisions USING btree (shopping_session_id);


--
-- Name: index_consent_records_on_active_policy; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_consent_records_on_active_policy ON public.consent_records USING btree (shopping_session_id, consent_kind, policy_version) WHERE (withdrawn_at IS NULL);


--
-- Name: index_consent_records_on_correlation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_consent_records_on_correlation_id ON public.consent_records USING btree (correlation_id);


--
-- Name: index_consent_records_on_id_and_shopping_session_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_consent_records_on_id_and_shopping_session_id ON public.consent_records USING btree (id, shopping_session_id);


--
-- Name: index_consent_records_on_shopping_session_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_consent_records_on_shopping_session_id ON public.consent_records USING btree (shopping_session_id);


--
-- Name: index_consent_records_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_consent_records_on_user_id ON public.consent_records USING btree (user_id);


--
-- Name: index_eligibility_results_on_product_fact_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_eligibility_results_on_product_fact_id ON public.eligibility_results USING btree (product_fact_id);


--
-- Name: index_eligibility_results_on_requirement_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_eligibility_results_on_requirement_id ON public.eligibility_results USING btree (requirement_id);


--
-- Name: index_eligibility_results_unique_candidate_requirement; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_eligibility_results_unique_candidate_requirement ON public.eligibility_results USING btree (recommendation_candidate_id, requirement_id);


--
-- Name: index_embedding_models_identity; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_embedding_models_identity ON public.embedding_models USING btree (provider, key, model_revision, configuration_hash);


--
-- Name: index_embeddings_content_uniqueness; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_embeddings_content_uniqueness ON public.embeddings USING btree (search_document_id, embedding_model_id, content_hash);


--
-- Name: index_embeddings_on_embedding_model_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_embeddings_on_embedding_model_id ON public.embeddings USING btree (embedding_model_id);


--
-- Name: index_embeddings_on_search_document_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_embeddings_on_search_document_id ON public.embeddings USING btree (search_document_id);


--
-- Name: index_embeddings_one_active_per_document_model; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_embeddings_one_active_per_document_model ON public.embeddings USING btree (search_document_id, embedding_model_id) WHERE (status = 'active'::text);


--
-- Name: index_external_identities_on_encryption_context; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_external_identities_on_encryption_context ON public.external_identities USING btree (encryption_context);


--
-- Name: index_external_identities_on_provider_subject; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_external_identities_on_provider_subject ON public.external_identities USING btree (provider, digest_key_version, provider_subject_digest);


--
-- Name: index_external_identities_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_external_identities_on_user_id ON public.external_identities USING btree (user_id);


--
-- Name: index_fact_definitions_on_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_fact_definitions_on_key ON public.fact_definitions USING btree (key);


--
-- Name: index_inventory_observations_current; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_inventory_observations_current ON public.inventory_observations USING btree (supplier_variant_id, supplier_warehouse_id, observed_at DESC, id DESC);


--
-- Name: index_inventory_observations_on_supplier_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_inventory_observations_on_supplier_id ON public.inventory_observations USING btree (supplier_id);


--
-- Name: index_inventory_observations_unique_source; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_inventory_observations_unique_source ON public.inventory_observations USING btree (supplier_variant_id, supplier_warehouse_id, supplier_observation_id);


--
-- Name: index_price_observations_current; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_price_observations_current ON public.price_observations USING btree (supplier_variant_id, price_kind, currency, observed_at DESC, id DESC);


--
-- Name: index_price_observations_on_supplier_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_price_observations_on_supplier_id ON public.price_observations USING btree (supplier_id);


--
-- Name: index_product_categories_on_category_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_product_categories_on_category_id ON public.product_categories USING btree (category_id);


--
-- Name: index_product_categories_on_product_id_and_category_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_product_categories_on_product_id_and_category_id ON public.product_categories USING btree (product_id, category_id);


--
-- Name: index_product_facts_active_boolean; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_product_facts_active_boolean ON public.product_facts USING btree (fact_definition_id, boolean_value, product_id, product_variant_id) WHERE ((status = 'active'::text) AND (boolean_value IS NOT NULL));


--
-- Name: index_product_facts_active_decimal; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_product_facts_active_decimal ON public.product_facts USING btree (fact_definition_id, decimal_value, product_id, product_variant_id) WHERE ((status = 'active'::text) AND (decimal_value IS NOT NULL));


--
-- Name: index_product_facts_active_integer; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_product_facts_active_integer ON public.product_facts USING btree (fact_definition_id, integer_value, product_id, product_variant_id) WHERE ((status = 'active'::text) AND (integer_value IS NOT NULL));


--
-- Name: index_product_facts_active_text; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_product_facts_active_text ON public.product_facts USING btree (fact_definition_id, text_value, product_id, product_variant_id) WHERE ((status = 'active'::text) AND (text_value IS NOT NULL));


--
-- Name: index_product_facts_on_fact_definition_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_product_facts_on_fact_definition_id ON public.product_facts USING btree (fact_definition_id);


--
-- Name: index_product_facts_on_product_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_product_facts_on_product_id ON public.product_facts USING btree (product_id);


--
-- Name: index_product_facts_on_product_variant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_product_facts_on_product_variant_id ON public.product_facts USING btree (product_variant_id);


--
-- Name: index_product_facts_on_supersedes_product_fact_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_product_facts_on_supersedes_product_fact_id ON public.product_facts USING btree (supersedes_product_fact_id);


--
-- Name: index_product_facts_on_supplier_observation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_product_facts_on_supplier_observation_id ON public.product_facts USING btree (supplier_observation_id);


--
-- Name: index_product_variants_on_canonical_sku; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_product_variants_on_canonical_sku ON public.product_variants USING btree (canonical_sku) WHERE (canonical_sku IS NOT NULL);


--
-- Name: index_product_variants_on_product_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_product_variants_on_product_id ON public.product_variants USING btree (product_id);


--
-- Name: index_product_variants_on_public_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_product_variants_on_public_id ON public.product_variants USING btree (public_id);


--
-- Name: index_products_on_primary_category_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_products_on_primary_category_id ON public.products USING btree (primary_category_id);


--
-- Name: index_products_on_public_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_products_on_public_id ON public.products USING btree (public_id);


--
-- Name: index_products_on_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_products_on_status ON public.products USING btree (status);


--
-- Name: index_recommendation_candidates_on_product_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_recommendation_candidates_on_product_id ON public.recommendation_candidates USING btree (product_id);


--
-- Name: index_recommendation_candidates_on_product_variant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_recommendation_candidates_on_product_variant_id ON public.recommendation_candidates USING btree (product_variant_id);


--
-- Name: index_recommendation_candidates_on_recommendation_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_recommendation_candidates_on_recommendation_run_id ON public.recommendation_candidates USING btree (recommendation_run_id);


--
-- Name: index_recommendation_candidates_unique_variant; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_recommendation_candidates_unique_variant ON public.recommendation_candidates USING btree (recommendation_run_id, product_id, COALESCE(product_variant_id, (0)::bigint));


--
-- Name: index_recommendation_evidence_on_inventory_observation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_recommendation_evidence_on_inventory_observation_id ON public.recommendation_evidence USING btree (inventory_observation_id);


--
-- Name: index_recommendation_evidence_on_price_observation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_recommendation_evidence_on_price_observation_id ON public.recommendation_evidence USING btree (price_observation_id);


--
-- Name: index_recommendation_evidence_on_product_fact_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_recommendation_evidence_on_product_fact_id ON public.recommendation_evidence USING btree (product_fact_id);


--
-- Name: index_recommendation_evidence_on_recommendation_candidate_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_recommendation_evidence_on_recommendation_candidate_id ON public.recommendation_evidence USING btree (recommendation_candidate_id);


--
-- Name: index_recommendation_evidence_on_supplier_observation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_recommendation_evidence_on_supplier_observation_id ON public.recommendation_evidence USING btree (supplier_observation_id);


--
-- Name: index_recommendation_runs_on_active_session; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_recommendation_runs_on_active_session ON public.recommendation_runs USING btree (shopping_session_id) WHERE (status = ANY (ARRAY['queued'::text, 'running'::text]));


--
-- Name: index_recommendation_runs_on_public_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_recommendation_runs_on_public_id ON public.recommendation_runs USING btree (public_id);


--
-- Name: index_recommendation_runs_on_purge_after; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_recommendation_runs_on_purge_after ON public.recommendation_runs USING btree (purge_after);


--
-- Name: index_requirements_on_active_session_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_requirements_on_active_session_key ON public.requirements USING btree (shopping_session_id, requirement_key) WHERE (status = 'active'::text);


--
-- Name: index_requirements_on_originating_message_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_requirements_on_originating_message_id ON public.requirements USING btree (originating_message_id);


--
-- Name: index_requirements_on_originating_tool_call_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_requirements_on_originating_tool_call_id ON public.requirements USING btree (originating_tool_call_id);


--
-- Name: index_requirements_on_public_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_requirements_on_public_id ON public.requirements USING btree (public_id);


--
-- Name: index_requirements_on_supersedes_requirement_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_requirements_on_supersedes_requirement_id ON public.requirements USING btree (supersedes_requirement_id);


--
-- Name: index_search_documents_active_search_vector; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_search_documents_active_search_vector ON public.search_documents USING gin (search_vector) WHERE (status = 'active'::text);


--
-- Name: index_search_documents_on_product_variant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_search_documents_on_product_variant_id ON public.search_documents USING btree (product_variant_id);


--
-- Name: index_search_documents_subject_kind_locale_version; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_search_documents_subject_kind_locale_version ON public.search_documents USING btree (product_id, product_variant_id, document_kind, locale, source_version);


--
-- Name: index_shopping_messages_on_ai_access_grant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_shopping_messages_on_ai_access_grant_id ON public.shopping_messages USING btree (ai_access_grant_id);


--
-- Name: index_shopping_messages_on_purge_after; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_shopping_messages_on_purge_after ON public.shopping_messages USING btree (purge_after);


--
-- Name: index_shopping_messages_on_session_sequence; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_shopping_messages_on_session_sequence ON public.shopping_messages USING btree (shopping_session_id, sequence);


--
-- Name: index_shopping_sessions_on_public_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_shopping_sessions_on_public_id ON public.shopping_sessions USING btree (public_id);


--
-- Name: index_shopping_sessions_on_status_and_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_shopping_sessions_on_status_and_expires_at ON public.shopping_sessions USING btree (status, expires_at);


--
-- Name: index_shopping_sessions_on_user_id_and_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_shopping_sessions_on_user_id_and_status ON public.shopping_sessions USING btree (user_id, status);


--
-- Name: index_supplier_observations_normalization_queue; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_supplier_observations_normalization_queue ON public.supplier_observations USING btree (normalization_status, received_at, id) WHERE ((purged_at IS NULL) AND (normalization_status = ANY (ARRAY['pending'::text, 'failed'::text])));


--
-- Name: index_supplier_observations_on_encryption_context; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_supplier_observations_on_encryption_context ON public.supplier_observations USING btree (encryption_context);


--
-- Name: index_supplier_observations_on_id_and_supplier_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_supplier_observations_on_id_and_supplier_id ON public.supplier_observations USING btree (id, supplier_id);


--
-- Name: index_supplier_observations_purge_queue; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_supplier_observations_purge_queue ON public.supplier_observations USING btree (purge_after, id) WHERE (purged_at IS NULL);


--
-- Name: index_supplier_observations_resource_chronology; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_supplier_observations_resource_chronology ON public.supplier_observations USING btree (supplier_id, resource_kind, external_resource_id, observed_at DESC, id DESC);


--
-- Name: index_supplier_products_on_id_and_supplier_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_supplier_products_on_id_and_supplier_id ON public.supplier_products USING btree (id, supplier_id);


--
-- Name: index_supplier_products_on_latest_observation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_supplier_products_on_latest_observation_id ON public.supplier_products USING btree (latest_observation_id);


--
-- Name: index_supplier_products_on_product_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_supplier_products_on_product_id ON public.supplier_products USING btree (product_id);


--
-- Name: index_supplier_products_on_supplier_id_and_external_product_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_supplier_products_on_supplier_id_and_external_product_id ON public.supplier_products USING btree (supplier_id, external_product_id);


--
-- Name: index_supplier_products_on_supplier_id_and_product_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_supplier_products_on_supplier_id_and_product_id ON public.supplier_products USING btree (supplier_id, product_id);


--
-- Name: index_supplier_subscriptions_logical; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_supplier_subscriptions_logical ON public.supplier_subscriptions USING btree (supplier_id, supplier_product_id, topic);


--
-- Name: index_supplier_subscriptions_on_encryption_context; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_supplier_subscriptions_on_encryption_context ON public.supplier_subscriptions USING btree (encryption_context);


--
-- Name: index_supplier_subscriptions_provider_ref; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_supplier_subscriptions_provider_ref ON public.supplier_subscriptions USING btree (supplier_id, topic, digest_key_version, external_ref_digest) WHERE (external_ref_digest IS NOT NULL);


--
-- Name: index_supplier_subscriptions_retry; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_supplier_subscriptions_retry ON public.supplier_subscriptions USING btree (next_retry_at, id) WHERE ((next_retry_at IS NOT NULL) AND (closed_at IS NULL));


--
-- Name: index_supplier_variants_on_id_and_supplier_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_supplier_variants_on_id_and_supplier_id ON public.supplier_variants USING btree (id, supplier_id);


--
-- Name: index_supplier_variants_on_latest_observation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_supplier_variants_on_latest_observation_id ON public.supplier_variants USING btree (latest_observation_id);


--
-- Name: index_supplier_variants_on_product_variant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_supplier_variants_on_product_variant_id ON public.supplier_variants USING btree (product_variant_id);


--
-- Name: index_supplier_variants_on_supplier_id_and_external_variant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_supplier_variants_on_supplier_id_and_external_variant_id ON public.supplier_variants USING btree (supplier_id, external_variant_id);


--
-- Name: index_supplier_variants_on_supplier_id_and_product_variant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_supplier_variants_on_supplier_id_and_product_variant_id ON public.supplier_variants USING btree (supplier_id, product_variant_id);


--
-- Name: index_supplier_variants_on_supplier_product_id_and_supplier_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_supplier_variants_on_supplier_product_id_and_supplier_id ON public.supplier_variants USING btree (supplier_product_id, supplier_id);


--
-- Name: index_supplier_warehouses_on_id_and_supplier_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_supplier_warehouses_on_id_and_supplier_id ON public.supplier_warehouses USING btree (id, supplier_id);


--
-- Name: index_suppliers_on_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_suppliers_on_key ON public.suppliers USING btree (key);


--
-- Name: index_sync_checkpoints_on_sync_run_id_and_checkpoint_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_sync_checkpoints_on_sync_run_id_and_checkpoint_key ON public.sync_checkpoints USING btree (sync_run_id, checkpoint_key);


--
-- Name: index_sync_runs_on_public_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_sync_runs_on_public_id ON public.sync_runs USING btree (public_id);


--
-- Name: index_sync_runs_scope_chronology; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sync_runs_scope_chronology ON public.sync_runs USING btree (supplier_id, resource_kind, scope_key, created_at DESC, id DESC);


--
-- Name: index_turnstile_verifications_on_id_and_shopping_session_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_turnstile_verifications_on_id_and_shopping_session_id ON public.turnstile_verifications USING btree (id, shopping_session_id);


--
-- Name: index_turnstile_verifications_on_purge_after; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_turnstile_verifications_on_purge_after ON public.turnstile_verifications USING btree (purge_after);


--
-- Name: index_turnstile_verifications_on_shopping_session_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_turnstile_verifications_on_shopping_session_id ON public.turnstile_verifications USING btree (shopping_session_id);


--
-- Name: index_turnstile_verifications_on_token_digest; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_turnstile_verifications_on_token_digest ON public.turnstile_verifications USING btree (token_digest);


--
-- Name: index_users_on_email_lookup; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_users_on_email_lookup ON public.users USING btree (email_digest_key_version, email_lookup_digest) WHERE (email_lookup_digest IS NOT NULL);


--
-- Name: index_users_on_public_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_users_on_public_id ON public.users USING btree (public_id);


--
-- Name: catalog_media db04_catalog_media_encryption_context; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER db04_catalog_media_encryption_context BEFORE UPDATE OF encryption_context ON public.catalog_media FOR EACH ROW EXECUTE FUNCTION public.db04_encryption_context_immutable();


--
-- Name: fact_definitions db04_fact_definition_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER db04_fact_definition_guard BEFORE INSERT OR UPDATE ON public.fact_definitions FOR EACH ROW EXECUTE FUNCTION public.db04_fact_definition_guard();


--
-- Name: inventory_observations db04_inventory_observations_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER db04_inventory_observations_immutable BEFORE DELETE OR UPDATE ON public.inventory_observations FOR EACH ROW EXECUTE FUNCTION public.nudge_prevent_row_mutation();


--
-- Name: price_observations db04_price_observations_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER db04_price_observations_immutable BEFORE DELETE OR UPDATE ON public.price_observations FOR EACH ROW EXECUTE FUNCTION public.nudge_prevent_row_mutation();


--
-- Name: product_facts db04_product_fact_validate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER db04_product_fact_validate BEFORE INSERT OR UPDATE ON public.product_facts FOR EACH ROW EXECUTE FUNCTION public.db04_product_fact_validate();


--
-- Name: supplier_observations db04_supplier_observation_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER db04_supplier_observation_guard BEFORE INSERT OR DELETE OR UPDATE ON public.supplier_observations FOR EACH ROW EXECUTE FUNCTION public.db04_supplier_observation_guard();


--
-- Name: supplier_products db04_supplier_products_latest_observation; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER db04_supplier_products_latest_observation BEFORE INSERT OR UPDATE OF latest_observation_id, supplier_id, external_product_id ON public.supplier_products FOR EACH ROW EXECUTE FUNCTION public.db04_latest_observation_validate();


--
-- Name: supplier_subscriptions db04_supplier_subscriptions_encryption_context; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER db04_supplier_subscriptions_encryption_context BEFORE UPDATE OF encryption_context ON public.supplier_subscriptions FOR EACH ROW EXECUTE FUNCTION public.db04_encryption_context_immutable();


--
-- Name: supplier_variants db04_supplier_variants_latest_observation; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER db04_supplier_variants_latest_observation BEFORE INSERT OR UPDATE OF latest_observation_id, supplier_id, external_variant_id ON public.supplier_variants FOR EACH ROW EXECUTE FUNCTION public.db04_latest_observation_validate();


--
-- Name: agent_runs fk_agent_runs_grant_session; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_runs
    ADD CONSTRAINT fk_agent_runs_grant_session FOREIGN KEY (ai_access_grant_id, shopping_session_id) REFERENCES public.ai_access_grants(id, shopping_session_id) ON DELETE SET NULL (ai_access_grant_id);


--
-- Name: agent_runs fk_agent_runs_provider_session; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_runs
    ADD CONSTRAINT fk_agent_runs_provider_session FOREIGN KEY (agent_provider_session_id, shopping_session_id) REFERENCES public.agent_provider_sessions(id, shopping_session_id) ON DELETE SET NULL (agent_provider_session_id);


--
-- Name: ai_access_grants fk_ai_grants_consent_session; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_access_grants
    ADD CONSTRAINT fk_ai_grants_consent_session FOREIGN KEY (disclosure_consent_record_id, shopping_session_id) REFERENCES public.consent_records(id, shopping_session_id) ON DELETE RESTRICT;


--
-- Name: ai_access_grants fk_ai_grants_turnstile_session; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_access_grants
    ADD CONSTRAINT fk_ai_grants_turnstile_session FOREIGN KEY (turnstile_verification_id, shopping_session_id) REFERENCES public.turnstile_verifications(id, shopping_session_id) ON DELETE SET NULL (turnstile_verification_id);


--
-- Name: inventory_observations fk_inventory_observations_source_supplier; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_observations
    ADD CONSTRAINT fk_inventory_observations_source_supplier FOREIGN KEY (supplier_observation_id, supplier_id) REFERENCES public.supplier_observations(id, supplier_id) ON UPDATE RESTRICT ON DELETE RESTRICT;


--
-- Name: inventory_observations fk_inventory_observations_supplier; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_observations
    ADD CONSTRAINT fk_inventory_observations_supplier FOREIGN KEY (supplier_id) REFERENCES public.suppliers(id) ON UPDATE RESTRICT ON DELETE RESTRICT;


--
-- Name: inventory_observations fk_inventory_observations_variant_supplier; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_observations
    ADD CONSTRAINT fk_inventory_observations_variant_supplier FOREIGN KEY (supplier_variant_id, supplier_id) REFERENCES public.supplier_variants(id, supplier_id) ON UPDATE RESTRICT ON DELETE RESTRICT;


--
-- Name: inventory_observations fk_inventory_observations_warehouse_supplier; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_observations
    ADD CONSTRAINT fk_inventory_observations_warehouse_supplier FOREIGN KEY (supplier_warehouse_id, supplier_id) REFERENCES public.supplier_warehouses(id, supplier_id) ON UPDATE RESTRICT ON DELETE RESTRICT;


--
-- Name: price_observations fk_price_observations_source_supplier; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.price_observations
    ADD CONSTRAINT fk_price_observations_source_supplier FOREIGN KEY (supplier_observation_id, supplier_id) REFERENCES public.supplier_observations(id, supplier_id) ON UPDATE RESTRICT ON DELETE RESTRICT;


--
-- Name: price_observations fk_price_observations_supplier; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.price_observations
    ADD CONSTRAINT fk_price_observations_supplier FOREIGN KEY (supplier_id) REFERENCES public.suppliers(id) ON UPDATE RESTRICT ON DELETE RESTRICT;


--
-- Name: price_observations fk_price_observations_variant_supplier; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.price_observations
    ADD CONSTRAINT fk_price_observations_variant_supplier FOREIGN KEY (supplier_variant_id, supplier_id) REFERENCES public.supplier_variants(id, supplier_id) ON UPDATE RESTRICT ON DELETE RESTRICT;


--
-- Name: products fk_products_primary_category_membership; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT fk_products_primary_category_membership FOREIGN KEY (id, primary_category_id) REFERENCES public.product_categories(product_id, category_id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: agent_provider_sessions fk_provider_sessions_grant_session; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_provider_sessions
    ADD CONSTRAINT fk_provider_sessions_grant_session FOREIGN KEY (ai_access_grant_id, shopping_session_id) REFERENCES public.ai_access_grants(id, shopping_session_id) ON DELETE RESTRICT;


--
-- Name: product_categories fk_rails_005b71ca83; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_categories
    ADD CONSTRAINT fk_rails_005b71ca83 FOREIGN KEY (category_id) REFERENCES public.categories(id) ON DELETE RESTRICT;


--
-- Name: clarification_decisions fk_rails_02bacf8dee; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.clarification_decisions
    ADD CONSTRAINT fk_rails_02bacf8dee FOREIGN KEY (selected_message_id) REFERENCES public.shopping_messages(id) ON DELETE SET NULL;


--
-- Name: product_facts fk_rails_0cbcdb0a9b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_facts
    ADD CONSTRAINT fk_rails_0cbcdb0a9b FOREIGN KEY (product_variant_id) REFERENCES public.product_variants(id) ON DELETE CASCADE;


--
-- Name: ai_access_grants fk_rails_0fc168a9d6; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_access_grants
    ADD CONSTRAINT fk_rails_0fc168a9d6 FOREIGN KEY (shopping_session_id) REFERENCES public.shopping_sessions(id) ON DELETE RESTRICT;


--
-- Name: product_facts fk_rails_1590454801; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_facts
    ADD CONSTRAINT fk_rails_1590454801 FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE CASCADE;


--
-- Name: recommendation_candidates fk_rails_16732abeaf; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recommendation_candidates
    ADD CONSTRAINT fk_rails_16732abeaf FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE RESTRICT;


--
-- Name: consent_records fk_rails_18fd9dc44f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.consent_records
    ADD CONSTRAINT fk_rails_18fd9dc44f FOREIGN KEY (shopping_session_id) REFERENCES public.shopping_sessions(id) ON DELETE RESTRICT;


--
-- Name: clarification_decisions fk_rails_1dc55f35e7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.clarification_decisions
    ADD CONSTRAINT fk_rails_1dc55f35e7 FOREIGN KEY (recommendation_run_id) REFERENCES public.recommendation_runs(id) ON DELETE SET NULL;


--
-- Name: eligibility_results fk_rails_2027cc487e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.eligibility_results
    ADD CONSTRAINT fk_rails_2027cc487e FOREIGN KEY (requirement_id) REFERENCES public.requirements(id) ON DELETE RESTRICT;


--
-- Name: eligibility_results fk_rails_2623e043ef; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.eligibility_results
    ADD CONSTRAINT fk_rails_2623e043ef FOREIGN KEY (product_fact_id) REFERENCES public.product_facts(id) ON DELETE RESTRICT;


--
-- Name: consent_records fk_rails_282f08b4f7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.consent_records
    ADD CONSTRAINT fk_rails_282f08b4f7 FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: catalog_media fk_rails_33b2a8131c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_media
    ADD CONSTRAINT fk_rails_33b2a8131c FOREIGN KEY (supplier_observation_id) REFERENCES public.supplier_observations(id) ON DELETE SET NULL;


--
-- Name: requirements fk_rails_3dad450e0f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.requirements
    ADD CONSTRAINT fk_rails_3dad450e0f FOREIGN KEY (shopping_session_id) REFERENCES public.shopping_sessions(id) ON DELETE CASCADE;


--
-- Name: sync_checkpoints fk_rails_41cc8be07d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sync_checkpoints
    ADD CONSTRAINT fk_rails_41cc8be07d FOREIGN KEY (sync_run_id) REFERENCES public.sync_runs(id) ON DELETE CASCADE;


--
-- Name: external_identities fk_rails_47162efee6; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.external_identities
    ADD CONSTRAINT fk_rails_47162efee6 FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: shopping_messages fk_rails_50523c6e63; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shopping_messages
    ADD CONSTRAINT fk_rails_50523c6e63 FOREIGN KEY (ai_access_grant_id) REFERENCES public.ai_access_grants(id) ON DELETE SET NULL;


--
-- Name: supplier_variants fk_rails_5d945c4b38; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supplier_variants
    ADD CONSTRAINT fk_rails_5d945c4b38 FOREIGN KEY (product_variant_id) REFERENCES public.product_variants(id) ON DELETE RESTRICT;


--
-- Name: agent_tool_calls fk_rails_637ac09801; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_tool_calls
    ADD CONSTRAINT fk_rails_637ac09801 FOREIGN KEY (agent_run_id) REFERENCES public.agent_runs(id) ON DELETE CASCADE;


--
-- Name: supplier_variants fk_rails_78f4694af5; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supplier_variants
    ADD CONSTRAINT fk_rails_78f4694af5 FOREIGN KEY (supplier_id) REFERENCES public.suppliers(id) ON DELETE RESTRICT;


--
-- Name: product_facts fk_rails_79715916d6; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_facts
    ADD CONSTRAINT fk_rails_79715916d6 FOREIGN KEY (fact_definition_id) REFERENCES public.fact_definitions(id) ON DELETE RESTRICT;


--
-- Name: search_documents fk_rails_79ae37d1f3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.search_documents
    ADD CONSTRAINT fk_rails_79ae37d1f3 FOREIGN KEY (product_variant_id) REFERENCES public.product_variants(id) ON DELETE CASCADE;


--
-- Name: recommendation_evidence fk_rails_79df78614f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recommendation_evidence
    ADD CONSTRAINT fk_rails_79df78614f FOREIGN KEY (product_fact_id) REFERENCES public.product_facts(id) ON DELETE RESTRICT;


--
-- Name: eligibility_results fk_rails_7cbd9f4e89; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.eligibility_results
    ADD CONSTRAINT fk_rails_7cbd9f4e89 FOREIGN KEY (recommendation_candidate_id) REFERENCES public.recommendation_candidates(id) ON DELETE CASCADE;


--
-- Name: categories fk_rails_82f48f7407; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.categories
    ADD CONSTRAINT fk_rails_82f48f7407 FOREIGN KEY (parent_id) REFERENCES public.categories(id) ON DELETE RESTRICT;


--
-- Name: recommendation_runs fk_rails_844955e6ca; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recommendation_runs
    ADD CONSTRAINT fk_rails_844955e6ca FOREIGN KEY (shopping_session_id) REFERENCES public.shopping_sessions(id) ON DELETE CASCADE;


--
-- Name: recommendation_evidence fk_rails_88f140565e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recommendation_evidence
    ADD CONSTRAINT fk_rails_88f140565e FOREIGN KEY (inventory_observation_id) REFERENCES public.inventory_observations(id) ON DELETE RESTRICT;


--
-- Name: supplier_products fk_rails_8e1c65b71a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supplier_products
    ADD CONSTRAINT fk_rails_8e1c65b71a FOREIGN KEY (supplier_id) REFERENCES public.suppliers(id) ON DELETE RESTRICT;


--
-- Name: recommendation_evidence fk_rails_97ca525b9d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recommendation_evidence
    ADD CONSTRAINT fk_rails_97ca525b9d FOREIGN KEY (price_observation_id) REFERENCES public.price_observations(id) ON DELETE RESTRICT;


--
-- Name: product_categories fk_rails_98a9a32a41; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_categories
    ADD CONSTRAINT fk_rails_98a9a32a41 FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE CASCADE;


--
-- Name: product_facts fk_rails_9971d96166; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_facts
    ADD CONSTRAINT fk_rails_9971d96166 FOREIGN KEY (supplier_observation_id) REFERENCES public.supplier_observations(id) ON DELETE RESTRICT;


--
-- Name: supplier_products fk_rails_9a363579c5; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supplier_products
    ADD CONSTRAINT fk_rails_9a363579c5 FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE RESTRICT;


--
-- Name: requirements fk_rails_9a8bc947ba; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.requirements
    ADD CONSTRAINT fk_rails_9a8bc947ba FOREIGN KEY (originating_tool_call_id) REFERENCES public.agent_tool_calls(id) ON DELETE SET NULL;


--
-- Name: recommendation_evidence fk_rails_9a9cd2a966; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recommendation_evidence
    ADD CONSTRAINT fk_rails_9a9cd2a966 FOREIGN KEY (recommendation_candidate_id) REFERENCES public.recommendation_candidates(id) ON DELETE CASCADE;


--
-- Name: recommendation_candidates fk_rails_a16d67cd28; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recommendation_candidates
    ADD CONSTRAINT fk_rails_a16d67cd28 FOREIGN KEY (product_variant_id) REFERENCES public.product_variants(id) ON DELETE RESTRICT;


--
-- Name: catalog_media fk_rails_a3f4d7937d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_media
    ADD CONSTRAINT fk_rails_a3f4d7937d FOREIGN KEY (product_variant_id) REFERENCES public.product_variants(id) ON DELETE CASCADE;


--
-- Name: recommendation_candidates fk_rails_a7a7423cb9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recommendation_candidates
    ADD CONSTRAINT fk_rails_a7a7423cb9 FOREIGN KEY (recommendation_run_id) REFERENCES public.recommendation_runs(id) ON DELETE CASCADE;


--
-- Name: embeddings fk_rails_a87a0137b4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.embeddings
    ADD CONSTRAINT fk_rails_a87a0137b4 FOREIGN KEY (search_document_id) REFERENCES public.search_documents(id) ON DELETE CASCADE;


--
-- Name: supplier_observations fk_rails_af15bf8fed; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supplier_observations
    ADD CONSTRAINT fk_rails_af15bf8fed FOREIGN KEY (supplier_id) REFERENCES public.suppliers(id) ON DELETE RESTRICT;


--
-- Name: clarification_decisions fk_rails_b0cc8d9996; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.clarification_decisions
    ADD CONSTRAINT fk_rails_b0cc8d9996 FOREIGN KEY (requirement_id) REFERENCES public.requirements(id) ON DELETE SET NULL;


--
-- Name: supplier_warehouses fk_rails_b6502f29ac; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supplier_warehouses
    ADD CONSTRAINT fk_rails_b6502f29ac FOREIGN KEY (supplier_id) REFERENCES public.suppliers(id) ON DELETE RESTRICT;


--
-- Name: sync_runs fk_rails_b65808c902; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sync_runs
    ADD CONSTRAINT fk_rails_b65808c902 FOREIGN KEY (supplier_id) REFERENCES public.suppliers(id) ON DELETE RESTRICT;


--
-- Name: search_documents fk_rails_bb18fac0bb; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.search_documents
    ADD CONSTRAINT fk_rails_bb18fac0bb FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE CASCADE;


--
-- Name: recommendation_evidence fk_rails_c19f83666f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recommendation_evidence
    ADD CONSTRAINT fk_rails_c19f83666f FOREIGN KEY (supplier_observation_id) REFERENCES public.supplier_observations(id) ON DELETE RESTRICT;


--
-- Name: products fk_rails_c98cb91966; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT fk_rails_c98cb91966 FOREIGN KEY (primary_category_id) REFERENCES public.categories(id) ON DELETE RESTRICT;


--
-- Name: requirements fk_rails_ccce84f25c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.requirements
    ADD CONSTRAINT fk_rails_ccce84f25c FOREIGN KEY (originating_message_id) REFERENCES public.shopping_messages(id) ON DELETE SET NULL;


--
-- Name: embeddings fk_rails_cd9e26c5f4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.embeddings
    ADD CONSTRAINT fk_rails_cd9e26c5f4 FOREIGN KEY (embedding_model_id) REFERENCES public.embedding_models(id) ON DELETE RESTRICT;


--
-- Name: shopping_messages fk_rails_ce3d4b27c5; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shopping_messages
    ADD CONSTRAINT fk_rails_ce3d4b27c5 FOREIGN KEY (shopping_session_id) REFERENCES public.shopping_sessions(id) ON DELETE CASCADE;


--
-- Name: product_variants fk_rails_dae52f850b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_variants
    ADD CONSTRAINT fk_rails_dae52f850b FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE CASCADE;


--
-- Name: agent_runs fk_rails_db0a375456; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_runs
    ADD CONSTRAINT fk_rails_db0a375456 FOREIGN KEY (shopping_session_id) REFERENCES public.shopping_sessions(id) ON DELETE CASCADE;


--
-- Name: shopping_sessions fk_rails_de779ffa76; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shopping_sessions
    ADD CONSTRAINT fk_rails_de779ffa76 FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: requirements fk_rails_e0ca4e43a8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.requirements
    ADD CONSTRAINT fk_rails_e0ca4e43a8 FOREIGN KEY (supersedes_requirement_id) REFERENCES public.requirements(id) ON DELETE RESTRICT;


--
-- Name: clarification_decisions fk_rails_f057674bdb; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.clarification_decisions
    ADD CONSTRAINT fk_rails_f057674bdb FOREIGN KEY (shopping_session_id) REFERENCES public.shopping_sessions(id) ON DELETE CASCADE;


--
-- Name: turnstile_verifications fk_rails_f0d48f06cc; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.turnstile_verifications
    ADD CONSTRAINT fk_rails_f0d48f06cc FOREIGN KEY (shopping_session_id) REFERENCES public.shopping_sessions(id) ON DELETE CASCADE;


--
-- Name: product_facts fk_rails_f20e5ac3e9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_facts
    ADD CONSTRAINT fk_rails_f20e5ac3e9 FOREIGN KEY (supersedes_product_fact_id) REFERENCES public.product_facts(id) ON DELETE RESTRICT;


--
-- Name: catalog_media fk_rails_f30bd63329; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_media
    ADD CONSTRAINT fk_rails_f30bd63329 FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE CASCADE;


--
-- Name: supplier_products fk_supplier_products_latest_observation; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supplier_products
    ADD CONSTRAINT fk_supplier_products_latest_observation FOREIGN KEY (latest_observation_id, supplier_id) REFERENCES public.supplier_observations(id, supplier_id) ON UPDATE RESTRICT ON DELETE RESTRICT;


--
-- Name: supplier_subscriptions fk_supplier_subscriptions_product_supplier; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supplier_subscriptions
    ADD CONSTRAINT fk_supplier_subscriptions_product_supplier FOREIGN KEY (supplier_product_id, supplier_id) REFERENCES public.supplier_products(id, supplier_id) ON UPDATE RESTRICT ON DELETE RESTRICT;


--
-- Name: supplier_subscriptions fk_supplier_subscriptions_supplier; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supplier_subscriptions
    ADD CONSTRAINT fk_supplier_subscriptions_supplier FOREIGN KEY (supplier_id) REFERENCES public.suppliers(id) ON UPDATE RESTRICT ON DELETE RESTRICT;


--
-- Name: supplier_variants fk_supplier_variants_latest_observation; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supplier_variants
    ADD CONSTRAINT fk_supplier_variants_latest_observation FOREIGN KEY (latest_observation_id, supplier_id) REFERENCES public.supplier_observations(id, supplier_id) ON UPDATE RESTRICT ON DELETE RESTRICT;


--
-- Name: supplier_variants fk_supplier_variants_product_supplier; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supplier_variants
    ADD CONSTRAINT fk_supplier_variants_product_supplier FOREIGN KEY (supplier_product_id, supplier_id) REFERENCES public.supplier_products(id, supplier_id) ON DELETE RESTRICT;


--
-- PostgreSQL database dump complete
--

SET search_path TO "$user", public;

INSERT INTO "schema_migrations" (version) VALUES
('20260920000006'),
('20260920000005'),
('20260920000004'),
('20260920000003'),
('20260920000002'),
('20260920000001');
