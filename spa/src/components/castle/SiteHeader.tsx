'use client';

import { useState } from 'react';
import Link from 'next/link';

export default function SiteHeader() {
  const [menuOpen, setMenuOpen] = useState(false);

  return (
    <header className="fixed top-0 left-0 right-0 z-50 px-4 sm:px-8 pt-[30px]" data-track-location="header">
      <div className="mx-auto max-w-[850px]">
        <div className="hidden md:flex items-center justify-between rounded-[16px] bg-[#161616] px-[10px] py-[10px] shadow-[0_1px_4px_-1px_rgba(0,0,0,0.11),0_1px_2px_-1px_rgba(0,0,0,0.12),0_6px_8px_-1px_rgba(0,0,0,0.04),inset_0_-1px_2px_-1px_rgba(0,0,0,0.05)]">
          <a data-track-button="true" data-track-label="header_logo" className="flex cursor-pointer items-center pl-2 active" href="/" data-status="active" aria-current="page">
            <img alt="QuidMint" className="h-[24px] w-auto cursor-pointer" src="/castle/images/brand/castle-logo.svg" />
          </a>
          <nav className="flex items-center gap-6">
            <div className="relative">
              <button data-track-label="header_accounts_toggle" className="flex items-center gap-1 text-[14px] font-semibold transition-colors hover:text-white text-white/80">Accounts<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-chevron-down h-3.5 w-3.5 transition-transform duration-200" aria-hidden="true">
                <path d="m6 9 6 6 6-6"></path>
              </svg>
              </button>
            </div>
            <a href="/integrations" className="text-[14px] font-semibold transition-colors hover:text-white text-white/80">Integrations</a>
            <div className="relative">
              <button data-track-label="header_resources_toggle" className="flex items-center gap-1 text-[14px] font-semibold transition-colors hover:text-white text-white/80">Resources<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-chevron-down h-3.5 w-3.5 transition-transform duration-200" aria-hidden="true">
                <path d="m6 9 6 6 6-6"></path>
              </svg>
              </button>
            </div>
            <a href="/about" className="text-[14px] font-semibold transition-colors hover:text-white text-white/80">About</a>
          </nav>
          <div className="flex items-center gap-2">
            <Link href="/app" className="text-[14px] font-semibold text-white transition-colors hover:text-white/80 px-3 py-2">Log In</Link>
            <Link href="/app" className="rounded-[12px] bg-white text-[#09090b] hover:bg-gray-100 text-[14px] font-semibold px-[14px] py-[10px] transition-colors">Sign Up</Link>
          </div>
        </div>
        <div className="md:hidden relative z-50">
          <div className="relative z-50 flex items-center justify-between bg-[#161616] px-4 py-3 shadow-[0_1px_4px_-1px_rgba(0,0,0,0.11),0_1px_2px_-1px_rgba(0,0,0,0.12),0_6px_8px_-1px_rgba(0,0,0,0.04),inset_0_-1px_2px_-1px_rgba(0,0,0,0.05)] rounded-[16px]">
            <a data-track-button="true" data-track-label="mobile_header_logo" className="flex cursor-pointer items-center active" href="/" data-status="active" aria-current="page">
              <img alt="QuidMint" className="h-[20px] w-auto cursor-pointer" src="/castle/images/brand/castle-logo.svg" />
            </a>
            <button data-track-label="mobile_menu_toggle" className="rounded-full p-2 text-white hover:bg-white/10" aria-label="Toggle menu" onClick={() => setMenuOpen(!menuOpen)}>
              <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="lucide lucide-menu" aria-hidden="true">
                <path d="M4 5h16"></path>
                <path d="M4 12h16"></path>
                <path d="M4 19h16"></path>
              </svg>
            </button>
          </div>
        </div>
      </div>
    </header>
  );
}
