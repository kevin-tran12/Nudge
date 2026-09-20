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
    CONSTRAINT product_variants_measurements_nonnegative_check CHECK ((((weight_value IS NULL) OR (weight_value >= (0)::numeric)) AND ((length_value IS NULL) OR (length_value >= (0)::numeric)) AND ((width_value IS NULL) OR (width_value >= (0)::numeric)) AND ((height_value IS NULL) OR (height_value >= (0)::numeric)))),
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
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


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
    CONSTRAINT supplier_variants_measurements_nonnegative_check CHECK ((((weight_value IS NULL) OR (weight_value >= (0)::numeric)) AND ((length_value IS NULL) OR (length_value >= (0)::numeric)) AND ((width_value IS NULL) OR (width_value >= (0)::numeric)) AND ((height_value IS NULL) OR (height_value >= (0)::numeric)))),
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
-- Name: ai_access_grants id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_access_grants ALTER COLUMN id SET DEFAULT nextval('public.ai_access_grants_id_seq'::regclass);


--
-- Name: categories id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.categories ALTER COLUMN id SET DEFAULT nextval('public.categories_id_seq'::regclass);


--
-- Name: consent_records id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.consent_records ALTER COLUMN id SET DEFAULT nextval('public.consent_records_id_seq'::regclass);


--
-- Name: external_identities id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.external_identities ALTER COLUMN id SET DEFAULT nextval('public.external_identities_id_seq'::regclass);


--
-- Name: product_categories id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_categories ALTER COLUMN id SET DEFAULT nextval('public.product_categories_id_seq'::regclass);


--
-- Name: product_variants id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_variants ALTER COLUMN id SET DEFAULT nextval('public.product_variants_id_seq'::regclass);


--
-- Name: products id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.products ALTER COLUMN id SET DEFAULT nextval('public.products_id_seq'::regclass);


--
-- Name: shopping_sessions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shopping_sessions ALTER COLUMN id SET DEFAULT nextval('public.shopping_sessions_id_seq'::regclass);


--
-- Name: supplier_products id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supplier_products ALTER COLUMN id SET DEFAULT nextval('public.supplier_products_id_seq'::regclass);


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
-- Name: categories categories_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.categories
    ADD CONSTRAINT categories_pkey PRIMARY KEY (id);


--
-- Name: consent_records consent_records_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.consent_records
    ADD CONSTRAINT consent_records_pkey PRIMARY KEY (id);


--
-- Name: external_identities external_identities_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.external_identities
    ADD CONSTRAINT external_identities_pkey PRIMARY KEY (id);


--
-- Name: product_categories product_categories_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_categories
    ADD CONSTRAINT product_categories_pkey PRIMARY KEY (id);


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
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: shopping_sessions shopping_sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shopping_sessions
    ADD CONSTRAINT shopping_sessions_pkey PRIMARY KEY (id);


--
-- Name: supplier_products supplier_products_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supplier_products
    ADD CONSTRAINT supplier_products_pkey PRIMARY KEY (id);


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
-- Name: index_agent_provider_sessions_on_active_session; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_agent_provider_sessions_on_active_session ON public.agent_provider_sessions USING btree (shopping_session_id) WHERE (status = ANY (ARRAY['starting'::text, 'active'::text]));


--
-- Name: index_agent_provider_sessions_on_encryption_context; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_agent_provider_sessions_on_encryption_context ON public.agent_provider_sessions USING btree (encryption_context);


--
-- Name: index_agent_provider_sessions_on_provider_ref; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_agent_provider_sessions_on_provider_ref ON public.agent_provider_sessions USING btree (provider, digest_key_version, provider_session_ref_digest) WHERE (provider_session_ref_digest IS NOT NULL);


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
-- Name: index_product_categories_on_category_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_product_categories_on_category_id ON public.product_categories USING btree (category_id);


--
-- Name: index_product_categories_on_product_id_and_category_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_product_categories_on_product_id_and_category_id ON public.product_categories USING btree (product_id, category_id);


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
-- Name: index_suppliers_on_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_suppliers_on_key ON public.suppliers USING btree (key);


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
-- Name: ai_access_grants fk_rails_0fc168a9d6; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_access_grants
    ADD CONSTRAINT fk_rails_0fc168a9d6 FOREIGN KEY (shopping_session_id) REFERENCES public.shopping_sessions(id) ON DELETE RESTRICT;


--
-- Name: consent_records fk_rails_18fd9dc44f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.consent_records
    ADD CONSTRAINT fk_rails_18fd9dc44f FOREIGN KEY (shopping_session_id) REFERENCES public.shopping_sessions(id) ON DELETE RESTRICT;


--
-- Name: consent_records fk_rails_282f08b4f7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.consent_records
    ADD CONSTRAINT fk_rails_282f08b4f7 FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: external_identities fk_rails_47162efee6; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.external_identities
    ADD CONSTRAINT fk_rails_47162efee6 FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: supplier_variants fk_rails_5d945c4b38; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supplier_variants
    ADD CONSTRAINT fk_rails_5d945c4b38 FOREIGN KEY (product_variant_id) REFERENCES public.product_variants(id) ON DELETE RESTRICT;


--
-- Name: supplier_variants fk_rails_78f4694af5; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supplier_variants
    ADD CONSTRAINT fk_rails_78f4694af5 FOREIGN KEY (supplier_id) REFERENCES public.suppliers(id) ON DELETE RESTRICT;


--
-- Name: categories fk_rails_82f48f7407; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.categories
    ADD CONSTRAINT fk_rails_82f48f7407 FOREIGN KEY (parent_id) REFERENCES public.categories(id) ON DELETE RESTRICT;


--
-- Name: supplier_products fk_rails_8e1c65b71a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supplier_products
    ADD CONSTRAINT fk_rails_8e1c65b71a FOREIGN KEY (supplier_id) REFERENCES public.suppliers(id) ON DELETE RESTRICT;


--
-- Name: product_categories fk_rails_98a9a32a41; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_categories
    ADD CONSTRAINT fk_rails_98a9a32a41 FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE CASCADE;


--
-- Name: supplier_products fk_rails_9a363579c5; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supplier_products
    ADD CONSTRAINT fk_rails_9a363579c5 FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE RESTRICT;


--
-- Name: supplier_warehouses fk_rails_b6502f29ac; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supplier_warehouses
    ADD CONSTRAINT fk_rails_b6502f29ac FOREIGN KEY (supplier_id) REFERENCES public.suppliers(id) ON DELETE RESTRICT;


--
-- Name: products fk_rails_c98cb91966; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT fk_rails_c98cb91966 FOREIGN KEY (primary_category_id) REFERENCES public.categories(id) ON DELETE RESTRICT;


--
-- Name: product_variants fk_rails_dae52f850b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_variants
    ADD CONSTRAINT fk_rails_dae52f850b FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE CASCADE;


--
-- Name: shopping_sessions fk_rails_de779ffa76; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shopping_sessions
    ADD CONSTRAINT fk_rails_de779ffa76 FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: turnstile_verifications fk_rails_f0d48f06cc; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.turnstile_verifications
    ADD CONSTRAINT fk_rails_f0d48f06cc FOREIGN KEY (shopping_session_id) REFERENCES public.shopping_sessions(id) ON DELETE CASCADE;


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
('20260920000003'),
('20260920000002'),
('20260920000001');
