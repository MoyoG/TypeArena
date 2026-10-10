import React from 'react';
import { createRoot } from 'react-dom/client';
import { createClient } from '@supabase/supabase-js';
import App from './App.jsx';
import './style.css';
const url = import.meta.env.VITE_SUPABASE_URL;
const key = import.meta.env.VITE_SUPABASE_ANON_KEY;
export const supabase = url && key ? createClient(url, key, {auth:{detectSessionInUrl:true, persistSession:true, autoRefreshToken:true}}) : null;
createRoot(document.getElementById('root')).render(<React.StrictMode><App/></React.StrictMode>);
