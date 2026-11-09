#pragma once
// Synthetic vectors independently checked against the selected official native functions.
// Plaintext byte i = i*7+1 (17 bytes); public test key byte i = i+32 (32 bytes).
struct CipherVector { unsigned kind; bool cbc; const char* encrypted; };
static const CipherVector cipher_vectors[] = {
  {0,false,"87b9ddf0d44178c0caa865060ed0861ad73f112f89ff15ead0a8f1787b058a1d"},
  {0,true,"c9e4191d784e04cf7f08eb485c1a5d4bac0dc615d81d01dce5a79380a2f37bb2"},
  {1,false,"88650e03883d6d9d9a1f44fd1c189245dc49a73f8ec38147"},
  {1,true,"c882f3d270a496bf23d9dfd51e7718e8fb24922baa93ec0a"},
  {2,false,"7b046919ea38cbf11c1dc357d44e29beb36975d301705d9fc1885008f63c2841"},
  {2,true,"c5ea26c2ead947d0bc134ad0fe18f930c359f466b92ea615105a69d78e95815e"},
  {3,false,"44af7d8c9f51007c5026bfd02701fcfeffb157a81b2f7a79"},
  {3,true,"3e5a1779eeadafc939b05415d480b2e2a433a4f65f6709df"},
  {4,false,"fd3154873ad9b5b56b33b1b98d522d4503a1ae8739bbbcce"},
  {4,true,"990f487026915600657b6cd50b36c4618839b9102a219860"},
  {5,false,"fd94af923bcfa4b7585c309b0fe6558a4fb89ad096604310"},
  {5,true,"3de3d878b92442120fb4d485afc0be16d4618c239c84b208"},
};
