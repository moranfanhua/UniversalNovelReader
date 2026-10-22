#include "qimei_json.hpp"
#include <stdexcept>
#include <utility>

namespace qimei {
namespace {
[[noreturn]] void invalid(){throw std::runtime_error("Invalid QIMEI JSON envelope");}
void utf8(std::string& text,std::uint32_t value){
  if(value<0x80)text+=char(value);
  else if(value<0x800){text+=char(0xc0|(value>>6));text+=char(0x80|(value&63));}
  else if(value<0x10000){text+=char(0xe0|(value>>12));text+=char(0x80|((value>>6)&63));text+=char(0x80|(value&63));}
  else{text+=char(0xf0|(value>>18));text+=char(0x80|((value>>12)&63));text+=char(0x80|((value>>6)&63));text+=char(0x80|(value&63));}
}
struct Parser {
  const std::string& input;std::size_t position=0;
  void spaces(){while(position<input.size()&&(input[position]==' '||input[position]=='\n'||input[position]=='\r'||input[position]=='\t'))++position;}
  bool take(char value){spaces();if(position<input.size()&&input[position]==value){++position;return true;}return false;}
  void expect(char value){if(!take(value))invalid();}
  std::uint32_t unit(){std::uint32_t out=0;for(int i=0;i<4;++i){if(position==input.size())invalid();char c=input[position++];unsigned digit;if(c>='0'&&c<='9')digit=unsigned(c-'0');else if(c>='a'&&c<='f')digit=unsigned(c-'a'+10);else if(c>='A'&&c<='F')digit=unsigned(c-'A'+10);else invalid();out=(out<<4)|digit;}return out;}
  std::string string(){
    expect('"');std::string out;
    while(position<input.size()){
      const auto c=static_cast<unsigned char>(input[position++]);if(c=='"')return out;if(c<0x20)invalid();
      if(c!='\\'){out+=char(c);continue;}
      if(position==input.size()){invalid();}
      const char escaped=input[position++];
      switch(escaped){
        case '"':case '\\':case '/':out+=escaped;break;
        case 'b':out+='\b';break;case 'f':out+='\f';break;case 'n':out+='\n';break;case 'r':out+='\r';break;case 't':out+='\t';break;
        case 'u':{
          auto value=unit();
          if(value>=0xd800&&value<=0xdbff&&position+6<=input.size()&&input[position]=='\\'&&input[position+1]=='u'){
            const auto saved=position;position+=2;const auto low=unit();if(low>=0xdc00&&low<=0xdfff)value=0x10000+((value-0xd800)<<10)+(low-0xdc00);else position=saved;
          }
          utf8(out,value);break;
        }
        default:invalid();
      }
    }
    invalid();
  }
  Json value(unsigned depth){
    if(depth>32){invalid();}
    spaces();if(position==input.size()){invalid();}
    Json out;
    if(input[position]=='"')return Json::string(string());
    if(take('{')){out.kind=Json::Kind::object;if(take('}'))return out;do{const auto key=string();expect(':');out.members[key]=value(depth+1);}while(take(','));expect('}');return out;}
    if(take('[')){out.kind=Json::Kind::array;if(take(']'))return out;do{out.items.push_back(value(depth+1));}while(take(','));expect(']');return out;}
    if(input.compare(position,4,"null")==0){position+=4;return out;}
    if(input.compare(position,4,"true")==0){position+=4;out.kind=Json::Kind::boolean;out.boolean=true;return out;}
    if(input.compare(position,5,"false")==0){position+=5;out.kind=Json::Kind::boolean;return out;}
    const auto start=position;if(input[position]=='-')++position;
    if(position==input.size())invalid();
    if(input[position]=='0')++position;else{if(input[position]<'1'||input[position]>'9')invalid();while(position<input.size()&&input[position]>='0'&&input[position]<='9')++position;}
    if(position<input.size()&&input[position]=='.'){++position;const auto begin=position;while(position<input.size()&&input[position]>='0'&&input[position]<='9')++position;if(begin==position)invalid();}
    if(position<input.size()&&(input[position]=='e'||input[position]=='E')){++position;if(position<input.size()&&(input[position]=='+'||input[position]=='-'))++position;const auto begin=position;while(position<input.size()&&input[position]>='0'&&input[position]<='9')++position;if(begin==position)invalid();}
    if(position-start>128){invalid();}
    out.kind=Json::Kind::number;out.text=input.substr(start,position-start);return out;
  }
};
std::string quote(const std::string& text){
  constexpr char hex[]="0123456789abcdef";std::string out="\"";
  for(const unsigned char c:text){if(c=='"'||c=='\\'){out+='\\';out+=char(c);}else if(c<0x20){out+="\\u00";out+=hex[c>>4];out+=hex[c&15];}else out+=char(c);}
  out+='"';return out;
}
}
Json Json::parse(const std::string& text){if(text.size()>2*1024*1024)invalid();Parser parser{text};auto result=parser.value(0);parser.spaces();if(parser.position!=text.size())invalid();return result;}
Json Json::string(std::string text){Json out;out.kind=Kind::string;out.text=std::move(text);return out;}
Json Json::number(std::int64_t number){Json out;out.kind=Kind::number;out.text=std::to_string(number);return out;}
Json Json::object(std::map<std::string,Json> members){Json out;out.kind=Kind::object;out.members=std::move(members);return out;}
const Json* Json::find(const std::string& name)const{if(kind!=Kind::object)return nullptr;const auto found=members.find(name);return found==members.end()?nullptr:&found->second;}
std::int64_t Json::integer(std::int64_t fallback)const{if(kind!=Kind::number||text.find_first_of(".eE")!=std::string::npos)return fallback;try{std::size_t end=0;auto result=std::stoll(text,&end);return end==text.size()?result:fallback;}catch(const std::exception&){return fallback;}}
std::string Json::string_or_empty()const{return kind==Kind::string?text:std::string();}
std::string Json::encode()const{
  switch(kind){
    case Kind::null_value:return "null";
    case Kind::boolean:return boolean?"true":"false";
    case Kind::number:return text;
    case Kind::string:return quote(text);
    case Kind::array:{std::string out="[";bool first=true;for(const auto& item:items){if(!first)out+=',';first=false;out+=item.encode();}return out+"]";}
    case Kind::object:{std::string out="{";bool first=true;for(const auto& [key,item]:members){if(!first)out+=',';first=false;out+=quote(key)+":"+item.encode();}return out+"}";}
  }
  invalid();
}
}
