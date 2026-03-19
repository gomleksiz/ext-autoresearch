-- ============================================================
-- Extension Requirements Tracker - Supabase Setup
-- Run this in: Supabase Dashboard > SQL Editor
-- ============================================================

-- 1. REQUESTS TABLE
-- ============================================================
CREATE TABLE public.requests (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    title TEXT NOT NULL,
    target_service TEXT NOT NULL,
    integration_type TEXT DEFAULT 'rest_api'
        CHECK (integration_type IN ('rest_api', 'cli', 'sdk', 'database', 'message_queue', 'other')),
    status TEXT DEFAULT 'new'
        CHECK (status IN ('new', 'researching', 'requirements_ready', 'in_review', 'approved', 'rejected')),
    priority TEXT DEFAULT 'medium'
        CHECK (priority IN ('low', 'medium', 'high', 'critical')),
    description TEXT,
    api_info TEXT,
    requirements_url TEXT,
    requested_by UUID REFERENCES auth.users(id),
    requested_by_email TEXT,
    requested_by_name TEXT,
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);

-- 2. COMMENTS TABLE
-- ============================================================
CREATE TABLE public.request_comments (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    request_id UUID REFERENCES public.requests(id) ON DELETE CASCADE NOT NULL,
    user_id UUID REFERENCES auth.users(id),
    user_email TEXT,
    user_name TEXT,
    comment TEXT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT now()
);

-- 3. INDEXES
-- ============================================================
CREATE INDEX idx_requests_status ON public.requests(status);
CREATE INDEX idx_requests_requested_by ON public.requests(requested_by);
CREATE INDEX idx_requests_created_at ON public.requests(created_at DESC);
CREATE INDEX idx_comments_request_id ON public.request_comments(request_id);

-- 4. ENABLE ROW LEVEL SECURITY
-- ============================================================
ALTER TABLE public.requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.request_comments ENABLE ROW LEVEL SECURITY;

-- 5. RLS POLICIES - REQUESTS
-- ============================================================
-- Authenticated users can read all requests
CREATE POLICY "Authenticated users can view requests"
    ON public.requests FOR SELECT
    TO authenticated
    USING (true);

-- Authenticated users can create requests
CREATE POLICY "Authenticated users can create requests"
    ON public.requests FOR INSERT
    TO authenticated
    WITH CHECK (auth.uid() = requested_by);

-- Users can update their own requests
CREATE POLICY "Users can update own requests"
    ON public.requests FOR UPDATE
    TO authenticated
    USING (auth.uid() = requested_by);

-- Users can delete their own requests
CREATE POLICY "Users can delete own requests"
    ON public.requests FOR DELETE
    TO authenticated
    USING (auth.uid() = requested_by);

-- 6. RLS POLICIES - COMMENTS
-- ============================================================
-- Authenticated users can view all comments
CREATE POLICY "Authenticated users can view comments"
    ON public.request_comments FOR SELECT
    TO authenticated
    USING (true);

-- Authenticated users can create comments
CREATE POLICY "Authenticated users can create comments"
    ON public.request_comments FOR INSERT
    TO authenticated
    WITH CHECK (auth.uid() = user_id);

-- 7. ENABLE REALTIME
-- ============================================================
ALTER PUBLICATION supabase_realtime ADD TABLE public.requests;
ALTER PUBLICATION supabase_realtime ADD TABLE public.request_comments;

-- 8. AUTO-UPDATE updated_at TRIGGER
-- ============================================================
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER requests_updated_at
    BEFORE UPDATE ON public.requests
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at();

-- ============================================================
-- OPTIONAL: Admin role for managing all requests
-- ============================================================
-- If you want certain users to be admins who can edit/delete
-- any request, add this custom claim approach:

-- Create an admins table
CREATE TABLE public.admins (
    user_id UUID PRIMARY KEY REFERENCES auth.users(id)
);

ALTER TABLE public.admins ENABLE ROW LEVEL SECURITY;

-- Only admins can read the admins table
CREATE POLICY "Admins can read admin list"
    ON public.admins FOR SELECT
    TO authenticated
    USING (true);

-- Helper function to check if user is admin
CREATE OR REPLACE FUNCTION is_admin()
RETURNS BOOLEAN AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1 FROM public.admins WHERE user_id = auth.uid()
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Admin policies: admins can update/delete any request
CREATE POLICY "Admins can update any request"
    ON public.requests FOR UPDATE
    TO authenticated
    USING (is_admin());

CREATE POLICY "Admins can delete any request"
    ON public.requests FOR DELETE
    TO authenticated
    USING (is_admin());

-- ============================================================
-- OPTIONAL: Service role access for AI agents
-- ============================================================
-- AI agents should use the service_role key (NOT the anon key).
-- The service_role key bypasses RLS entirely, so agents can:
--   - Read all requests
--   - Update status to 'researching', 'requirements_ready'
--   - Set requirements_url after generating requirements.md
--   - Add comments
--
-- NEVER expose the service_role key in frontend code.
-- Use it only in server-side agent code.
--
-- Example agent usage (Python):
--
--   from supabase import create_client
--   supabase = create_client(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)
--
--   # Get new requests to research
--   result = supabase.table('requests').select('*').eq('status', 'new').execute()
--
--   # Update status after research
--   supabase.table('requests').update({
--       'status': 'requirements_ready',
--       'requirements_url': 'https://github.com/...'
--   }).eq('id', request_id).execute()
