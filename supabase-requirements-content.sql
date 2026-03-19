-- ============================================================
-- Add requirements_content column to requests table
-- Run this in: Supabase Dashboard > SQL Editor
-- ============================================================

ALTER TABLE public.requests ADD COLUMN IF NOT EXISTS requirements_content TEXT;
